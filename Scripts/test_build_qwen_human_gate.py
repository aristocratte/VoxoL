import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("build-qwen-human-gate.py")
SPEC = importlib.util.spec_from_file_location("human_gate", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def source(identifier, split="train", language="fr", provenance="human"):
    return {
        "id": identifier, "split": split, "split_group": identifier, "language": language,
        "raw_transcript": f"raw {identifier}", "target_text": f"corrected {identifier}",
        "source": provenance, "approved": True,
    }


def inputs(rows, rejected=()):
    prepared = [{"id": row["id"], "normalized_text": row["raw_transcript"]} for row in rows]
    summary = {split: sum(row["split"] == split and row["id"] not in rejected for row in rows) for split in MODULE.SPLITS}
    summary["rejected_ids"] = list(rejected)
    return rows, prepared, summary


class HumanGateTests(unittest.TestCase):
    def test_teacher_approval_is_not_human_review(self):
        for provenance in ("wispr-teacher-product-reference", "agent-context-adjudicated", "human-authored", "synthetic-reviewed"):
            with self.subTest(provenance=provenance):
                result = MODULE.evaluate(*inputs([source("one", provenance=provenance)]))
                self.assertEqual(result["human_reviewed_correction_count"], 0)
                self.assertFalse(result["promotion_training_eligible"])

    def test_exact_threshold_and_clean_parent(self):
        rows = [source(f"{split}-{language}-{i}", split, language)
                for split, language, count in (("train", "fr", 175), ("train", "en", 175), ("validation", "fr", 75), ("test", "en", 75))
                for i in range(count)]
        result = MODULE.evaluate(*inputs(rows))
        self.assertTrue(result["promotion_training_eligible"])
        self.assertEqual(result["human_reviewed_correction_count"], 500)
        self.assertEqual(result["human_reviewed_evaluation_count"], 150)
        self.assertEqual(result["training_parent_revision"], MODULE.PARENT_REVISION)
        self.assertEqual(result["schema_version"], "voxol-qwen-human-gate-v2")

    def test_rejected_noop_and_nonboolean_approval_do_not_count(self):
        rows = [source("reject"), source("noop"), source("string"), source("valid")]
        rows[1]["target_text"] = rows[1]["raw_transcript"]
        rows[2]["approved"] = "true"
        result = MODULE.evaluate(*inputs(rows, rejected=("reject",)))
        self.assertEqual(result["human_reviewed_correction_count"], 1)

    def test_synthetic_is_train_only_and_never_satisfies_human_quota(self):
        train = MODULE.evaluate(*inputs([source("synthetic", provenance="synthetic-reviewed")]))
        self.assertEqual(train["unreviewed_accepted_example_count"], 0)
        self.assertEqual(train["human_reviewed_correction_count"], 0)
        heldout = MODULE.evaluate(*inputs([source("synthetic", split="test", provenance="synthetic-reviewed")]))
        self.assertEqual(heldout["unreviewed_accepted_example_count"], 1)
        self.assertIn("unreviewed_or_nonhuman_heldout_examples", heldout["blocking_reasons"])

    def test_faithful_rewrite_duplicates_count_once(self):
        rows = [source("faithful"), source("rewrite")]
        rows[1]["raw_transcript"] = " RAW   faithful "
        result = MODULE.evaluate(*inputs(rows))
        self.assertEqual(result["human_reviewed_correction_count"], 1)

    def test_group_and_relabelled_text_leakage_block(self):
        rows = [source("train"), source("test", "test")]
        rows[1]["split_group"] = rows[0]["split_group"]
        result = MODULE.evaluate(*inputs(rows))
        self.assertIn("split_group_crossing", result["blocking_reasons"])
        rows[1]["split_group"] = "renamed-group"
        rows[1]["raw_transcript"] = rows[0]["raw_transcript"]
        result = MODULE.evaluate(*inputs(rows))
        self.assertIn("raw_text_crossing", result["blocking_reasons"])

    def test_invalid_coverage_is_not_silently_dropped(self):
        rows, prepared, summary = inputs([source("one")])
        for bad_rows, bad_prepared, bad_summary in (
            (rows * 2, prepared, summary), (rows, prepared * 2, summary),
            (rows, [], summary), (rows, prepared, {**summary, "train": 2}),
            (rows, prepared, {**summary, "rejected_ids": ["unknown"]}),
        ):
            with self.subTest(summary=bad_summary), self.assertRaises(ValueError):
                MODULE.evaluate(bad_rows, bad_prepared, bad_summary)

    def test_cli_binds_all_inputs_and_check_never_writes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            rows, prepared, summary = inputs([source("one")])
            payloads = {
                "source/source.jsonl": rows, "prepared-source.jsonl": prepared,
                "source/evaluation-reference.jsonl": rows,
                "mlx-data/train.jsonl": [{"messages": []}], "mlx-data/valid.jsonl": [],
                "mlx-data/test.jsonl": [],
            }
            for filename, values in payloads.items():
                path = root / filename
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("".join(json.dumps(value) + "\n" for value in values))
            (root / "mlx-data/summary.json").write_text(json.dumps(summary))
            command = [sys.executable, str(SCRIPT), "--root", str(root)]
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)
            gate = root / "qwen-mass-gate.json"
            original = gate.read_bytes()
            blocked = subprocess.run(command + ["--check"], capture_output=True)
            self.assertEqual(blocked.returncode, 1)
            self.assertIn(b"human_corrections_below_500", blocked.stdout)
            self.assertEqual(gate.read_bytes(), original)
            (root / "mlx-data/train.jsonl").write_text('{"messages":["changed"]}\n')
            stale = subprocess.run(command + ["--check"], capture_output=True)
            self.assertEqual(stale.returncode, 1)
            self.assertIn(b"stale", stale.stderr)
            self.assertEqual(gate.read_bytes(), original)
            (root / "mlx-data/train.jsonl").write_text("")
            with self.assertRaisesRegex(ValueError, "row count"):
                MODULE.build(root)


if __name__ == "__main__":
    unittest.main()
