#!/usr/bin/env python3
"""Unit tests for the local Qwen fine-tuning orchestration."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("run_qwen_wispr_finetune.py")
sys.path.insert(0, str(SCRIPT.parent))
SPEC = importlib.util.spec_from_file_location("run_qwen_wispr_finetune", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
RUNNER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = RUNNER
SPEC.loader.exec_module(RUNNER)


class QwenWisprFineTuneRunnerTests(unittest.TestCase):
    def test_config_adapts_both_qwen_attention_families(self) -> None:
        config = RUNNER.training_config(
            model=Path("/model"),
            dataset=Path("/dataset"),
            adapter=Path("/adapter"),
            resume_adapter_file=None,
            iterations=1200,
            learning_rate=5e-5,
        )

        keys = config["lora_parameters"]["keys"]
        self.assertIn("self_attn.q_proj", keys)
        self.assertIn("linear_attn.in_proj_qkv", keys)
        self.assertEqual(config["max_seq_length"], 512)
        self.assertTrue(config["mask_prompt"])
        self.assertNotIn("resume_adapter_file", config)

    def test_config_can_resume_from_an_adapter_checkpoint(self) -> None:
        checkpoint = Path("/checkpoint/adapters.safetensors")
        config = RUNNER.training_config(
            model=Path("/model"),
            dataset=Path("/dataset"),
            adapter=Path("/adapter"),
            resume_adapter_file=checkpoint,
            iterations=200,
            learning_rate=5e-5,
        )

        self.assertEqual(config["resume_adapter_file"], str(checkpoint))

    def test_quality_gate_requires_gain_and_fidelity(self) -> None:
        baseline = {
            "metrics": {
                "microWordEditRate": 0.20,
                "protectedTokenRecall": 0.90,
                "unexpectedWordRate": 0.03,
            }
        }
        candidate = {
            "metrics": {
                "microWordEditRate": 0.15,
                "protectedTokenRecall": 1.0,
                "unexpectedWordRate": 0.02,
            }
        }

        self.assertTrue(RUNNER.quality_gate(baseline, candidate)["passed"])

    def runtime_report(
        self,
        *,
        accepted: int,
        fallback: int,
        recall: float,
    ) -> dict[str, object]:
        return {
            "modelOutputCount": accepted,
            "fallbackCount": fallback,
            "metrics": {"protectedTokenRecall": recall},
            "fallbackReasonCounts": {},
        }

    def gate_with_runtime(
        self,
        candidate_runtime: dict[str, object] | None,
        baseline_runtime: dict[str, object] | None = None,
    ) -> dict[str, object]:
        good = {
            "metrics": {
                "microWordEditRate": 0.20,
                "protectedTokenRecall": 0.90,
                "unexpectedWordRate": 0.03,
            }
        }
        better = {
            "metrics": {
                "microWordEditRate": 0.15,
                "protectedTokenRecall": 0.99,
                "unexpectedWordRate": 0.02,
            }
        }
        return RUNNER.quality_gate(good, better, baseline_runtime, candidate_runtime)

    def test_gate_asserts_protected_spans_on_the_text_the_app_inserts(self) -> None:
        # The plan's criterion is "100% after runtime fallback". The 2026-08-04
        # candidate generated 99.195% raw and the runtime guaranteed 100%; the
        # old absolute raw threshold rejected it for missing a bar nobody set.
        gate = self.gate_with_runtime(
            self.runtime_report(accepted=1320, fallback=62, recall=1.0)
        )

        self.assertTrue(gate["checks"]["protectedSpansIntactAfterRuntimeFallback"])
        self.assertTrue(gate["checks"]["rawProtectedTokenRecallDoesNotRegress"])

    def test_gate_rejects_a_runtime_that_loses_a_protected_span(self) -> None:
        gate = self.gate_with_runtime(
            self.runtime_report(accepted=1320, fallback=62, recall=0.998)
        )

        self.assertFalse(gate["checks"]["protectedSpansIntactAfterRuntimeFallback"])
        self.assertFalse(gate["passed"])

    def test_gate_rejects_a_candidate_the_runtime_falls_back_on_more_often(
        self,
    ) -> None:
        # Word error can improve while the app ships the deterministic pass more
        # often, which is a worse product however good the accepted outputs are.
        gate = self.gate_with_runtime(
            self.runtime_report(accepted=800, fallback=582, recall=1.0),
            self.runtime_report(accepted=898, fallback=484, recall=1.0),
        )

        self.assertFalse(gate["checks"]["runtimeAcceptanceDoesNotRegress"])

    def test_gate_accepts_a_large_acceptance_gain(self) -> None:
        gate = self.gate_with_runtime(
            self.runtime_report(accepted=1320, fallback=62, recall=1.0),
            self.runtime_report(accepted=898, fallback=484, recall=1.0),
        )

        self.assertTrue(gate["checks"]["runtimeAcceptanceDoesNotRegress"])
        self.assertAlmostEqual(gate["runtime"]["baselineAcceptanceRate"], 898 / 1382)
        self.assertAlmostEqual(gate["runtime"]["candidateAcceptanceRate"], 1320 / 1382)

    def test_gate_omits_runtime_checks_when_validation_did_not_run(self) -> None:
        # A machine without a release build still has to produce a verdict
        # rather than fail at the last step.
        gate = self.gate_with_runtime(None)

        self.assertNotIn("protectedSpansIntactAfterRuntimeFallback", gate["checks"])
        self.assertNotIn("runtimeAcceptanceDoesNotRegress", gate["checks"])
        self.assertFalse(gate["runtime"]["measured"])

    def test_raw_recall_regression_still_fails(self) -> None:
        gate = RUNNER.quality_gate(
            {
                "metrics": {
                    "microWordEditRate": 0.20,
                    "protectedTokenRecall": 0.99,
                    "unexpectedWordRate": 0.03,
                }
            },
            {
                "metrics": {
                    "microWordEditRate": 0.15,
                    "protectedTokenRecall": 0.80,
                    "unexpectedWordRate": 0.02,
                }
            },
        )

        self.assertFalse(gate["checks"]["rawProtectedTokenRecallDoesNotRegress"])

    def test_runtime_acceptance_is_the_share_shipped_from_the_model(self) -> None:
        self.assertAlmostEqual(
            RUNNER.runtime_acceptance(
                self.runtime_report(accepted=1320, fallback=62, recall=1.0)
            ),
            1320 / 1382,
        )
        self.assertEqual(RUNNER.runtime_acceptance(None), 0.0)
        self.assertEqual(
            RUNNER.runtime_acceptance(
                self.runtime_report(accepted=0, fallback=0, recall=1.0)
            ),
            0.0,
        )

    def gate_with_latency(
        self,
        baseline_p95: float | None,
        candidate_p95: float | None,
    ) -> dict[str, object]:
        """A gate that passes on every axis except, optionally, latency."""

        def metrics(wer: float, recall: float, p95: float | None) -> dict[str, object]:
            payload: dict[str, object] = {
                "microWordEditRate": wer,
                "protectedTokenRecall": recall,
                "unexpectedWordRate": 0.01,
            }
            if p95 is not None:
                payload["latencyMilliseconds"] = {"p50": p95 / 2, "p95": p95}
            return payload

        return RUNNER.quality_gate(
            {"metrics": metrics(0.20, 0.90, baseline_p95)},
            {"metrics": metrics(0.15, 1.0, candidate_p95)},
        )

    def test_quality_gate_rejects_a_p95_latency_regression(self) -> None:
        # The 2026-08-04 candidate won 90% relative on word error while adding
        # 432 ms at p95. Every other check passed, so without this one the gate
        # would have blessed a slower dictation experience.
        gate = self.gate_with_latency(1587.9, 2019.7)

        self.assertFalse(gate["checks"]["p95LatencyRegressionAtMost10Percent"])
        self.assertFalse(gate["passed"])
        self.assertAlmostEqual(gate["latency"]["relativeP95Change"], 0.2719, places=3)

    def test_quality_gate_accepts_latency_inside_the_envelope(self) -> None:
        gate = self.gate_with_latency(1000.0, 1090.0)

        self.assertTrue(gate["checks"]["p95LatencyRegressionAtMost10Percent"])
        self.assertTrue(gate["passed"])

    def test_quality_gate_accepts_a_faster_candidate(self) -> None:
        gate = self.gate_with_latency(1000.0, 700.0)

        self.assertTrue(gate["checks"]["p95LatencyRegressionAtMost10Percent"])
        self.assertAlmostEqual(gate["latency"]["relativeP95Change"], -0.30)

    def test_quality_gate_reports_the_ceiling_it_applied(self) -> None:
        gate = self.gate_with_latency(1000.0, 1200.0)

        self.assertAlmostEqual(
            gate["latency"]["maximumAcceptedP95Milliseconds"],
            1000.0 * (1 + RUNNER.MAXIMUM_P95_LATENCY_REGRESSION),
        )

    def test_quality_gate_survives_a_report_without_latency(self) -> None:
        # Older reports predate the latency block; a missing measurement must
        # not crash the verdict.
        gate = self.gate_with_latency(None, None)

        self.assertTrue(gate["checks"]["p95LatencyRegressionAtMost10Percent"])
        self.assertEqual(gate["latency"]["baselineP95Milliseconds"], 0.0)
        self.assertEqual(gate["latency"]["relativeP95Change"], 0.0)

    def test_quality_gate_rejects_a_language_slice_regression(self) -> None:
        baseline = {
            "metrics": {
                "microWordEditRate": 0.20,
                "protectedTokenRecall": 1.0,
                "unexpectedWordRate": 0.01,
            },
            "slices": {
                "fr-edit": {"exampleCount": 10, "microWordEditRate": 0.10},
            },
        }
        candidate = {
            "metrics": {
                "microWordEditRate": 0.15,
                "protectedTokenRecall": 1.0,
                "unexpectedWordRate": 0.01,
            },
            "slices": {
                "fr-edit": {"exampleCount": 10, "microWordEditRate": 0.11},
            },
        }

        gate = RUNNER.quality_gate(baseline, candidate)

        self.assertFalse(gate["passed"])
        self.assertFalse(
            gate["checks"]["fr-editWordEditRateRegressionAtMost0Point5Point"]
        )

    def test_training_filter_updates_records_and_summary(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            dataset = Path(directory)
            records = [
                {"messages": [{"role": "user", "content": "short"}]},
                {"messages": [{"role": "user", "content": "x" * 50}]},
            ]
            (dataset / "train.jsonl").write_text(
                "".join(json.dumps(record) + "\n" for record in records),
                encoding="utf-8",
            )
            (dataset / "summary.json").write_text(
                json.dumps({"train": 2, "validation": 0, "test": 0}),
                encoding="utf-8",
            )

            dropped = RUNNER.filter_training_records(dataset, 10)

            self.assertEqual(dropped, 1)
            self.assertEqual(
                len((dataset / "train.jsonl").read_text().splitlines()),
                1,
            )
            self.assertEqual(
                json.loads((dataset / "summary.json").read_text())["train"],
                1,
            )

    def test_curriculum_merge_accepts_only_approved_training_rows(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.jsonl"
            curriculum = root / "curriculum.jsonl"
            report = root / "report.json"
            source.write_text(
                json.dumps({"id": "teacher", "split": "test"}) + "\n",
                encoding="utf-8",
            )
            curriculum.write_text(
                json.dumps(
                    {
                        "approved": True,
                        "id": "curated",
                        "split": "train",
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            result = RUNNER.append_training_curriculum(source, curriculum, report)

            rows = [json.loads(line) for line in source.read_text().splitlines()]
            self.assertEqual([row["id"] for row in rows], ["curated", "teacher"])
            self.assertEqual(result["curriculumExampleCount"], 1)
            self.assertTrue(report.is_file())

    def test_curriculum_merge_rejects_validation_rows(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.jsonl"
            curriculum = root / "curriculum.jsonl"
            source.write_text(
                json.dumps({"id": "teacher", "split": "test"}) + "\n",
                encoding="utf-8",
            )
            curriculum.write_text(
                json.dumps(
                    {
                        "approved": True,
                        "id": "leak",
                        "split": "validation",
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            with self.assertRaises(SystemExit):
                RUNNER.append_training_curriculum(
                    source,
                    curriculum,
                    root / "report.json",
                )

    def test_curriculum_only_replaces_teacher_training_rows(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.jsonl"
            curriculum = root / "curriculum.jsonl"
            report = root / "report.json"
            source.write_text(
                json.dumps({"id": "teacher", "split": "train"}) + "\n",
                encoding="utf-8",
            )
            curriculum.write_text(
                json.dumps(
                    {
                        "approved": True,
                        "id": "curated",
                        "split": "train",
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            result = RUNNER.append_training_curriculum(
                source,
                curriculum,
                report,
                curriculum_only=True,
            )

            rows = [json.loads(line) for line in source.read_text().splitlines()]
            self.assertEqual([row["id"] for row in rows], ["curated"])
            self.assertTrue(result["curriculumOnly"])
            self.assertEqual(result["originalExampleCount"], 1)

    def test_curriculum_only_does_not_require_a_teacher_source(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "prepared" / "missing-source.jsonl"
            curriculum = root / "curriculum.jsonl"
            curriculum.write_text(
                json.dumps(
                    {
                        "approved": True,
                        "id": "curated",
                        "split": "train",
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            result = RUNNER.append_training_curriculum(
                source,
                curriculum,
                root / "report.json",
                curriculum_only=True,
            )

            rows = [json.loads(line) for line in source.read_text().splitlines()]
            self.assertEqual([row["id"] for row in rows], ["curated"])
            self.assertEqual(result["originalExampleCount"], 0)

    def test_frozen_evaluation_restores_exact_files(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepared = root / "prepared"
            frozen = root / "frozen"
            (prepared / "mlx").mkdir(parents=True)
            (frozen / "mlx").mkdir(parents=True)
            (prepared / "mlx" / "summary.json").write_text(
                json.dumps({"train": 5, "validation": 9, "test": 9}),
                encoding="utf-8",
            )
            (prepared / "mlx" / "valid.jsonl").write_text("stale\n", encoding="utf-8")
            (prepared / "mlx" / "test.jsonl").write_text("stale\n", encoding="utf-8")
            (prepared / "evaluation-reference.jsonl").write_text(
                "stale\n",
                encoding="utf-8",
            )
            (frozen / "mlx" / "valid.jsonl").write_text("v1\nv2\n", encoding="utf-8")
            (frozen / "mlx" / "test.jsonl").write_text("t1\n", encoding="utf-8")
            (frozen / "mlx" / "summary.json").write_text(
                json.dumps({"rejected_ids": ["frozen-rejection"]}),
                encoding="utf-8",
            )
            (frozen / "evaluation-reference.jsonl").write_text(
                "reference\n",
                encoding="utf-8",
            )

            report = RUNNER.restore_frozen_evaluation(prepared, frozen)

            self.assertEqual((prepared / "mlx" / "valid.jsonl").read_text(), "v1\nv2\n")
            self.assertEqual((prepared / "mlx" / "test.jsonl").read_text(), "t1\n")
            self.assertEqual(
                (prepared / "evaluation-reference.jsonl").read_text(),
                "reference\n",
            )
            self.assertEqual(report["validationCount"], 2)
            self.assertEqual(report["testCount"], 1)
            summary = json.loads((prepared / "mlx" / "summary.json").read_text())
            self.assertEqual(summary["rejected_ids"], ["frozen-rejection"])

    def test_compact_format_is_accepted_by_cli(self) -> None:
        previous = sys.argv
        try:
            sys.argv = [
                "runner",
                "--output-format",
                "compact-edits",
                "--compact-training-edits-only",
                "--training-curriculum",
                "/tmp/curriculum.jsonl",
                "--curriculum-only",
                "--frozen-evaluation-root",
                "/tmp/frozen",
                "--lora-rank",
                "8",
                "--train-top-layers",
                "8",
                "--smoke",
            ]
            arguments = RUNNER.parse_arguments()
        finally:
            sys.argv = previous

        self.assertEqual(arguments.output_format, "compact-edits")
        self.assertTrue(arguments.compact_training_edits_only)
        self.assertEqual(
            arguments.training_curriculum,
            Path("/tmp/curriculum.jsonl"),
        )
        self.assertEqual(arguments.frozen_evaluation_root, Path("/tmp/frozen"))
        self.assertTrue(arguments.curriculum_only)
        self.assertEqual(arguments.lora_rank, 8)
        self.assertEqual(arguments.train_top_layers, 8)
        self.assertTrue(arguments.smoke)

    def test_prepared_dataset_cli_keeps_baseline_adapter(self) -> None:
        previous = sys.argv
        try:
            sys.argv = [
                "runner",
                "--prepared-dataset",
                "/tmp/mlx",
                "--evaluation-references",
                "/tmp/references.jsonl",
                "--baseline-adapter",
                "/tmp/v6-adapter",
            ]
            arguments = RUNNER.parse_arguments()
        finally:
            sys.argv = previous

        self.assertEqual(arguments.prepared_dataset, Path("/tmp/mlx"))
        self.assertEqual(
            arguments.evaluation_references,
            Path("/tmp/references.jsonl"),
        )
        self.assertEqual(arguments.baseline_adapter, Path("/tmp/v6-adapter"))


if __name__ == "__main__":
    unittest.main()
