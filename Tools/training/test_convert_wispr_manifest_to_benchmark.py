#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest


SCRIPT = Path(__file__).with_name("convert_wispr_manifest_to_benchmark.py")
SPEC = importlib.util.spec_from_file_location("convert_wispr_manifest_to_benchmark", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ConvertWisprManifestTests(unittest.TestCase):
    def test_keeps_only_complete_boundaries_and_frozen_splits(self) -> None:
        rows = [
            {
                "audio_path": "records/one.wav",
                "boundary_complete": True,
                "duration": 8,
                "id": "one",
                "raw": "hello there",
                "recording_id": "recording-one",
                "requested_language": "en",
                "speaker_id": "speaker-one",
            },
            {
                "audio_path": "records/two.wav",
                "boundary_complete": False,
                "duration": 8,
                "id": "two",
                "raw": "bonjour ici",
                "recording_id": "recording-two",
                "requested_language": "fr",
            },
        ]
        items = MODULE.convert(
            rows,
            {"recording-one": "train", "recording-two": "test"},
            require_complete_boundary=True,
        )
        self.assertEqual([item["id"] for item in items], ["one"])
        self.assertEqual(items[0]["split"], "calibration")
        self.assertEqual(items[0]["language"], "english")

    def sample_rows(self) -> list[dict[str, object]]:
        return [
            {
                "audio_path": "records/one.wav",
                "boundary_complete": True,
                "duration": 8,
                "id": "one",
                "raw": "hello there",
                "recording_id": "recording-one",
                "requested_language": "en",
                "speaker_id": "speaker-one",
            }
        ]

    def test_emits_every_field_the_swift_decoder_requires(self) -> None:
        # ASRBenchmarkItem declares these non-optional, so a missing key makes
        # `voxol-asr-benchmark validate` abort with a keyNotFound decode error
        # rather than a readable message.
        items = MODULE.convert(
            self.sample_rows(),
            {"recording-one": "train"},
            require_complete_boundary=True,
        )
        required = {
            "id",
            "audioPath",
            "speakerID",
            "sessionID",
            "split",
            "language",
            "microphone",
            "environment",
            "tags",
            "reference",
        }
        self.assertEqual(required - set(items[0]), set())

    def test_session_identifies_the_recording_that_carries_the_split(self) -> None:
        # The Swift manifest rejects a session spread over two splits, and the
        # frozen split is assigned per recording, so the two must be the same
        # identifier or that rule silently stops protecting anything.
        items = MODULE.convert(
            self.sample_rows(),
            {"recording-one": "train"},
            require_complete_boundary=True,
        )
        self.assertEqual(items[0]["sessionID"], "recording-one")
        self.assertEqual(items[0]["recordingID"], items[0]["sessionID"])

    def test_reference_carries_the_flag_the_swift_runner_demands(self) -> None:
        # Not a claim that a human read it: ASRBenchmarkKit throws
        # unreviewedReference on any unflagged item, and the established
        # adapter sets the same flag for this same teacher corpus.
        items = MODULE.convert(
            self.sample_rows(),
            {"recording-one": "train"},
            require_complete_boundary=True,
        )
        self.assertTrue(items[0]["reference"]["reviewed"])

    def test_reference_text_is_the_teacher_output_verbatim(self) -> None:
        items = MODULE.convert(
            self.sample_rows(),
            {"recording-one": "train"},
            require_complete_boundary=True,
        )
        self.assertEqual(items[0]["reference"]["verbatim"], "hello there")
        self.assertEqual(items[0]["reference"]["clean"], "hello there")

    def test_machine_learning_splits_map_onto_benchmark_roles(self) -> None:
        # ASRBenchmarkSplit only knows evaluation roles, so an unmapped
        # "train"/"validation"/"test" reaches Swift as an opaque decode failure.
        self.assertEqual(MODULE.benchmark_split("train"), "calibration")
        self.assertEqual(MODULE.benchmark_split("validation"), "development")
        self.assertEqual(MODULE.benchmark_split("test"), "blind")

    def test_every_mapped_role_is_one_the_swift_enum_declares(self) -> None:
        declared = {"development", "calibration", "blind", "stress"}
        self.assertEqual(set(MODULE.BENCHMARK_SPLITS.values()) - declared, set())

    def test_an_unknown_split_fails_with_a_readable_message(self) -> None:
        with self.assertRaises(RuntimeError) as raised:
            MODULE.benchmark_split("holdout")
        self.assertIn("ASRBenchmarkSplit", str(raised.exception))

    def test_the_mapping_is_injective_so_partitions_stay_distinguishable(
        self,
    ) -> None:
        values = list(MODULE.BENCHMARK_SPLITS.values())
        self.assertEqual(len(values), len(set(values)))


if __name__ == "__main__":
    unittest.main()
