#!/usr/bin/env python3
"""Tests for the campaign completion estimator."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPOSITORY_ROOT / "Scripts" / "campaign-eta.py"
SPEC = importlib.util.spec_from_file_location("campaign_eta", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
ETA = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = ETA
SPEC.loader.exec_module(ETA)


def build_campaign(root: Path, sources: list[tuple[str, float]]) -> None:
    corpus = root / "corpus"
    corpus.mkdir(parents=True, exist_ok=True)
    rows = [
        json.dumps(
            {
                "source_id": name.removesuffix(".mka"),
                "original_path": f"{root}/corpus/originals/fr/{name}",
                "duration_seconds": duration,
                "language": "fr",
            }
        )
        for name, duration in sources
    ]
    (corpus / "manifest.jsonl").write_text("\n".join(rows) + "\n", encoding="utf-8")


def finish_source(root: Path, name: str, duration: float, chunks: int) -> Path:
    records = root / "corpus" / "transcripts" / "dataset" / "records"
    directory = records / name.removesuffix(".mka").replace("_", "-")
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / "record.json"
    path.write_text(
        json.dumps(
            {
                "recording_id": directory.name,
                "source": {"name": name, "duration_seconds": duration},
                "results": [{"raw_http_status": "200"} for _ in range(chunks)],
            }
        ),
        encoding="utf-8",
    )
    return path


class ManifestTests(unittest.TestCase):
    def test_reads_every_planned_source_by_file_name(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            build_campaign(root, [("a.mka", 600.0), ("b.mka", 1200.0)])
            self.assertEqual(
                ETA.read_manifest(root),
                {"a.mka": 600.0, "b.mka": 1200.0},
            )

    def test_falls_back_to_the_estimated_duration(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            (root / "corpus").mkdir(parents=True)
            (root / "corpus" / "manifest.jsonl").write_text(
                json.dumps(
                    {
                        "original_path": "/x/c.mka",
                        "duration_seconds": None,
                        "expected_duration_seconds": 300.0,
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            self.assertEqual(ETA.read_manifest(root), {"c.mka": 300.0})

    def test_missing_manifest_is_fatal(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            with self.assertRaises(SystemExit):
                ETA.read_manifest(Path(raw))


class FinishedTests(unittest.TestCase):
    def test_counts_sources_audio_and_chunks(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            finish_source(root, "a.mka", 600.0, 30)
            finish_source(root, "b.mka", 1200.0, 60)
            finished, seconds, chunks = ETA.read_finished(root)
            self.assertEqual(finished, {"a.mka", "b.mka"})
            self.assertEqual(seconds, 1800.0)
            self.assertEqual(chunks, 90)

    def test_a_half_written_record_is_skipped_not_fatal(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            finish_source(root, "a.mka", 600.0, 30)
            partial = (
                root / "corpus" / "transcripts" / "dataset" / "records" / "in-flight"
            )
            partial.mkdir(parents=True)
            (partial / "record.json").write_text('{"source": {"na', encoding="utf-8")
            finished, seconds, chunks = ETA.read_finished(root)
            self.assertEqual(finished, {"a.mka"})
            self.assertEqual(chunks, 30)

    def test_an_untouched_campaign_reports_nothing_finished(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            self.assertEqual(ETA.read_finished(Path(raw)), (set(), 0.0, 0))


class LogCounterTests(unittest.TestCase):
    def write_log(self, root: Path, body: str) -> Path:
        logs = root / "logs"
        logs.mkdir(parents=True, exist_ok=True)
        path = logs / "reserve-and-finalize-20260803-173335.log"
        path.write_text(body, encoding="utf-8")
        return path

    def test_separates_genuine_collection_from_reuse(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            path = self.write_log(
                root,
                "  chunk 1/3 collected\n"
                "  chunk 2/3 reused\n"
                "  chunk 3/3 reused\n"
                "[worker-1 12/74] something\n",
            )
            counters = ETA.log_counters(path)
            self.assertEqual(counters["collected"], 1)
            self.assertEqual(counters["reused"], 2)
            self.assertEqual(counters["queueDone"], 12)
            self.assertEqual(counters["queueTotal"], 74)

    def test_ignores_lines_that_merely_mention_collection(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            path = self.write_log(
                root,
                "Teacher dataset: in progress, 124 recording(s), 12402 collected chunks\n"
                "[1/1] collected creator_bijan-bowen_ptdu0jlhgfw (0.62h)\n"
                "  chunk 1/3 collected\n"
                "Done. 1 file(s), 0 failed -> /somewhere\n",
            )
            counters = ETA.log_counters(path)
            self.assertEqual(counters["collected"], 1)
            self.assertEqual(counters["reused"], 0)

    def test_absent_log_yields_zero_counters(self) -> None:
        counters = ETA.log_counters(None)
        self.assertEqual(counters["collected"], 0)
        self.assertIsNone(counters["identity"])

    def test_picks_the_most_recent_run_log(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            logs = root / "logs"
            logs.mkdir(parents=True)
            old = logs / "reserve-and-finalize-20260803-040515.log"
            new = logs / "reserve-and-finalize-20260803-173335.log"
            old.write_text("old\n", encoding="utf-8")
            new.write_text("new\n", encoding="utf-8")
            import os

            os.utime(old, (1_000_000, 1_000_000))
            os.utime(new, (2_000_000, 2_000_000))
            self.assertEqual(ETA.active_log(root), new)


class FreshRateTests(unittest.TestCase):
    def sample(
        self,
        timestamp: float,
        collected: int,
        identity: str = "a",
        reused: int = 0,
    ) -> dict:
        return {
            "timestamp": timestamp,
            "collected": collected,
            "reused": reused,
            "logIdentity": identity,
        }

    def test_reports_the_fresh_share_of_the_window(self) -> None:
        samples = [
            self.sample(0, 100, reused=1000),
            self.sample(60, 130, reused=1010),
        ]
        _, _, _, share = ETA.fresh_rate(samples, 30)
        self.assertAlmostEqual(share, 30 / 40)

    def test_a_rewalk_window_reports_a_near_zero_fresh_share(self) -> None:
        samples = [
            self.sample(0, 19, reused=5000),
            self.sample(60, 20, reused=5300),
        ]
        rate, _, _, share = ETA.fresh_rate(samples, 30)
        self.assertGreater(rate, 0)  # non-zero, yet not projectable
        self.assertLess(share, ETA.FRESH_SHARE_FOR_ETA)

    def test_a_single_sample_cannot_produce_a_rate(self) -> None:
        rate, _, _, _ = ETA.fresh_rate([self.sample(0, 0)], 30)
        self.assertIsNone(rate)

    def test_rate_is_chunks_per_minute_between_samples(self) -> None:
        samples = [self.sample(0, 100), self.sample(120, 160)]
        rate, elapsed, _, _ = ETA.fresh_rate(samples, 30)
        self.assertAlmostEqual(rate, 30.0)
        self.assertAlmostEqual(elapsed, 120)

    def test_a_rewalk_phase_reports_a_zero_rate_not_a_guess(self) -> None:
        samples = [self.sample(0, 100), self.sample(120, 100)]
        rate, _, _, _ = ETA.fresh_rate(samples, 30)
        self.assertEqual(rate, 0.0)

    def test_a_rotated_log_does_not_produce_negative_progress(self) -> None:
        # The counter restarts at zero in the new log; that pair is skipped.
        samples = [
            self.sample(0, 500, "log-a"),
            self.sample(60, 10, "log-b"),
            self.sample(120, 40, "log-b"),
        ]
        rate, elapsed, _, _ = ETA.fresh_rate(samples, 30)
        self.assertAlmostEqual(rate, 30.0)
        self.assertAlmostEqual(elapsed, 60)

    def test_samples_outside_the_window_are_ignored(self) -> None:
        samples = [
            self.sample(0, 0),
            self.sample(60, 6000),  # ancient burst, must not skew the estimate
            self.sample(100_000, 7000),
            self.sample(100_060, 7010),
        ]
        rate, _, _, _ = ETA.fresh_rate(samples, 30)
        self.assertAlmostEqual(rate, 10.0)

    def test_falls_back_to_the_last_pair_when_the_window_is_empty(self) -> None:
        samples = [self.sample(0, 0), self.sample(60, 30)]
        rate, _, _, _ = ETA.fresh_rate(samples, 0.001)
        self.assertAlmostEqual(rate, 30.0)


class HistoricalRateTests(unittest.TestCase):
    def write_run(self, root: Path, stamp: str, collected: int, reused: int) -> Path:
        import os

        logs = root / "logs"
        logs.mkdir(parents=True, exist_ok=True)
        path = logs / f"reserve-and-finalize-{stamp}.log"
        body = "".join(
            [f"  chunk {i + 1}/{collected} collected\n" for i in range(collected)]
            + [f"  chunk {i + 1}/{reused} reused\n" for i in range(reused)]
        )
        path.write_text(body, encoding="utf-8")
        started = ETA.datetime.strptime(stamp, "%Y%m%d-%H%M%S").timestamp()
        os.utime(path, (started + 3600, started + 3600))  # one hour of runtime
        return path

    def test_derives_chunks_per_minute_from_a_finished_run(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            self.write_run(root, "20260803-040515", 600, 0)
            rate, chunks, minutes = ETA.historical_rate(root)
            self.assertAlmostEqual(rate, 10.0)  # 600 chunks over 60 minutes
            self.assertEqual(chunks, 600)
            self.assertAlmostEqual(minutes, 60.0)

    def test_skips_a_run_that_merely_rewalked(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            self.write_run(root, "20260803-040515", 250, 5_000)
            self.assertEqual(ETA.historical_rate(root), (None, 0, 0.0))

    def test_skips_a_run_too_small_to_mean_anything(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            self.write_run(root, "20260803-040515", 5, 0)
            self.assertEqual(ETA.historical_rate(root), (None, 0, 0.0))

    def test_aggregates_several_finished_runs(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            self.write_run(root, "20260803-040515", 600, 0)
            self.write_run(root, "20260803-120000", 1_200, 0)
            rate, chunks, minutes = ETA.historical_rate(root)
            self.assertEqual(chunks, 1_800)
            self.assertAlmostEqual(minutes, 120.0)
            self.assertAlmostEqual(rate, 15.0)

    def test_no_logs_yield_no_history(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            self.assertEqual(ETA.historical_rate(Path(raw)), (None, 0, 0.0))

    def test_history_supplies_the_eta_while_the_run_rewalks(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            build_campaign(root, [("a.mka", 600.0), ("b.mka", 3600.0)])
            finish_source(root, "a.mka", 600.0, 30)
            self.write_run(root, "20260803-040515", 600, 0)
            samples = root / "logs" / "eta-samples.jsonl"
            now = ETA.time.time()
            for offset, collected, reused in ((-120, 19, 5_000), (-60, 20, 5_300)):
                ETA.append_sample(
                    samples,
                    {
                        "timestamp": now + offset,
                        "collected": collected,
                        "reused": reused,
                        "logIdentity": None,
                    },
                )
            state = ETA.measure(root, 30.0, samples)
            self.assertFalse(state["rateIsRepresentative"])
            self.assertEqual(state["etaBasis"], "historique")
            # 3600 s of audio at 20 s per chunk is 180 chunks, at 10 chunks/min.
            self.assertAlmostEqual(state["etaSeconds"], 180 / 10 * 60)
            self.assertIn("débit historique", ETA.render(state))


class FormattingTests(unittest.TestCase):
    def test_renders_seconds_minutes_and_hours(self) -> None:
        self.assertEqual(ETA.format_duration(45), "45 s")
        self.assertEqual(ETA.format_duration(600), "10 min")
        self.assertEqual(ETA.format_duration(3_600), "1 h 00 min")
        self.assertEqual(ETA.format_duration(7_830), "2 h 10 min")


class MeasureTests(unittest.TestCase):
    def test_remaining_work_comes_from_the_manifest_not_a_guess(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            build_campaign(
                root,
                [("a.mka", 600.0), ("b.mka", 1200.0), ("c.mka", 1800.0)],
            )
            finish_source(root, "a.mka", 600.0, 30)
            samples = root / "logs" / "eta-samples.jsonl"
            state = ETA.measure(root, 30.0, samples)
            self.assertEqual(state["plannedSources"], 3)
            self.assertEqual(state["finishedSources"], 1)
            self.assertEqual(state["remainingSources"], 2)
            self.assertAlmostEqual(state["remainingHours"], 3000 / 3600)
            self.assertAlmostEqual(state["meanChunkSeconds"], 20.0)
            self.assertAlmostEqual(state["remainingChunks"], 150.0)

    def test_a_finished_campaign_reports_no_remainder(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            build_campaign(root, [("a.mka", 600.0)])
            finish_source(root, "a.mka", 600.0, 30)
            state = ETA.measure(root, 30.0, root / "logs" / "eta-samples.jsonl")
            self.assertEqual(state["remainingSources"], 0)
            self.assertEqual(state["remainingChunks"], 0)
            self.assertIn("TERMINÉ", ETA.render(state))

    def test_each_measurement_appends_exactly_one_sample(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            build_campaign(root, [("a.mka", 600.0), ("b.mka", 600.0)])
            finish_source(root, "a.mka", 600.0, 30)
            samples = root / "logs" / "eta-samples.jsonl"
            ETA.measure(root, 30.0, samples)
            ETA.measure(root, 30.0, samples)
            self.assertEqual(len(ETA.load_samples(samples)), 2)

    def test_a_rewalk_rate_is_never_projected_into_an_eta(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            build_campaign(root, [("a.mka", 600.0), ("b.mka", 3600.0)])
            finish_source(root, "a.mka", 600.0, 30)
            samples = root / "logs" / "eta-samples.jsonl"
            samples.parent.mkdir(parents=True, exist_ok=True)
            # One fresh chunk against 300 reused: a re-walk, whatever the rate.
            now = ETA.time.time()
            for offset, collected, reused in ((-120, 19, 5000), (-60, 20, 5300)):
                ETA.append_sample(
                    samples,
                    {
                        "timestamp": now + offset,
                        "collected": collected,
                        "reused": reused,
                        "logIdentity": None,
                    },
                )
            state = ETA.measure(root, 30.0, samples)
            self.assertGreater(state["freshChunksPerMinute"], 0)
            self.assertFalse(state["rateIsRepresentative"])
            self.assertIsNone(state["etaSeconds"])
            self.assertIn("non projetable", ETA.render(state))

    def test_a_genuine_collection_window_does_produce_an_eta(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            build_campaign(root, [("a.mka", 600.0), ("b.mka", 3600.0)])
            finish_source(root, "a.mka", 600.0, 30)
            samples = root / "logs" / "eta-samples.jsonl"
            samples.parent.mkdir(parents=True, exist_ok=True)
            now = ETA.time.time()
            for offset, collected, reused in ((-120, 0, 0), (-60, 30, 2)):
                ETA.append_sample(
                    samples,
                    {
                        "timestamp": now + offset,
                        "collected": collected,
                        "reused": reused,
                        "logIdentity": None,
                    },
                )
            state = ETA.measure(root, 30.0, samples)
            self.assertTrue(state["rateIsRepresentative"])
            self.assertIsNotNone(state["etaSeconds"])
            self.assertIn("ETA", ETA.render(state))

    def test_the_report_renders_without_a_measurable_rate(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            build_campaign(root, [("a.mka", 600.0), ("b.mka", 600.0)])
            finish_source(root, "a.mka", 600.0, 30)
            state = ETA.measure(root, 30.0, root / "logs" / "eta-samples.jsonl")
            self.assertIsNone(state["freshChunksPerMinute"])
            self.assertIn("pas encore mesurable", ETA.render(state))


if __name__ == "__main__":
    unittest.main()
