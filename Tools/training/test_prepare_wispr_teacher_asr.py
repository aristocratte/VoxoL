#!/usr/bin/env python3
"""Tests for the leakage-safe Wispr teacher ASR dataset builder."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import shutil
import sys
import tarfile
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("prepare_wispr_teacher_asr.py")
SPEC = importlib.util.spec_from_file_location("prepare_wispr_teacher_asr", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
BUILDER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = BUILDER
SPEC.loader.exec_module(BUILDER)


def write_manifest(path: Path, root: Path) -> None:
    rows = []
    for language in ("en", "fr"):
        for source_index in range(4):
            recording = f"{language}-source-{source_index}"
            speaker = (
                f"{language}-shared"
                if source_index in (0, 1)
                else f"{language}-speaker-{source_index}"
            )
            for chunk in range(1, 3):
                relative = f"records/{recording}/audio/chunk_{chunk:04d}.wav"
                audio = root / relative
                audio.parent.mkdir(parents=True, exist_ok=True)
                audio.write_bytes(
                    b"RIFF"
                    + language.encode("ascii")
                    + bytes([source_index, chunk])
                    + b"\0" * 92
                )
                rows.append(
                    {
                        "audio_path": relative,
                        "audio_sha256": BUILDER.sha256(audio),
                        "chunk": chunk,
                        "detected_language": language,
                        "duration": 10.0,
                        "id": f"{recording}-chunk-{chunk:04d}",
                        "raw": (
                            "one"
                            if language == "en" and source_index == 3 and chunk == 2
                            else "this transcript has enough words for the audio"
                        ),
                        "raw_http_status": "200",
                        "recording_id": recording,
                        "requested_language": language,
                        "speaker_id": speaker,
                        "usable_for_asr": True,
                    }
                )
    path.write_text(
        "".join(
            json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n"
            for row in rows
        ),
        encoding="utf-8",
    )


class WisprTeacherASRBuilderTests(unittest.TestCase):
    def test_amara_subtitle_credit_is_excluded_from_asr_training(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            audio = root / "records/source/audio/chunk_0001.wav"
            audio.parent.mkdir(parents=True)
            audio.write_bytes(b"RIFF" + b"\0" * 96)
            row = {
                "audio_path": "records/source/audio/chunk_0001.wav",
                "audio_sha256": BUILDER.sha256(audio),
                "detected_language": "fr",
                "duration": 2.15,
                "id": "source-chunk-0001",
                "raw": "Sous-titres réalisés para la communauté d'Amara.org",
                "raw_http_status": "200",
                "recording_id": "source",
                "requested_language": "fr",
                "speaker_id": "unknown",
                "usable_for_asr": True,
            }

            reasons = BUILDER.quality_reasons(root, row, set())

            self.assertIn("transcription_credit_boilerplate", reasons)

    def test_splits_are_speaker_disjoint_and_archive_contains_exact_audio(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dataset = root / "dataset"
            manifest = dataset / "all-manifest.jsonl"
            manifest.parent.mkdir(parents=True)
            write_manifest(manifest, dataset)
            output = root / "prepared"
            archive = root / "dataset.tar.gz"

            report = BUILDER.prepare(
                manifest,
                dataset,
                output,
                archive,
                BUILDER.FREEZE_TIMESTAMP,
            )

            self.assertEqual(report["filter"]["excludedItemCount"], 1)
            self.assertEqual(report["filter"]["includedItemCount"], 15)
            for overlap in report["overlapChecks"].values():
                self.assertEqual(overlap["recordings"], [])
                self.assertEqual(overlap["speakers"], [])
            groups = report["groups"]
            shared = [
                group
                for group in groups
                if f"{group['language']}-shared" in group["speakers"]
            ]
            self.assertEqual(len(shared), 2)
            self.assertTrue(all(len(group["recordings"]) == 2 for group in shared))

            with tarfile.open(archive, "r:gz") as source:
                names = source.getnames()
                self.assertEqual(
                    len([name for name in names if "/audio/" in name]),
                    15,
                )
                self.assertFalse(any("/._" in name for name in names))
                self.assertTrue(
                    all(
                        name.startswith(f"{BUILDER.PACKAGE_ROOT}/")
                        for name in names
                    )
                )

    def test_assignment_is_deterministic(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dataset = root / "dataset"
            manifest = dataset / "all-manifest.jsonl"
            manifest.parent.mkdir(parents=True)
            write_manifest(manifest, dataset)

            first = BUILDER.prepare(
                manifest,
                dataset,
                root / "first",
                None,
                BUILDER.FREEZE_TIMESTAMP,
            )
            second = BUILDER.prepare(
                manifest,
                dataset,
                root / "second",
                None,
                BUILDER.FREEZE_TIMESTAMP,
            )

            first_assignments = {
                group["identifier"]: group["split"] for group in first["groups"]
            }
            second_assignments = {
                group["identifier"]: group["split"] for group in second["groups"]
            }
            self.assertEqual(first_assignments, second_assignments)

    def test_multiple_corpora_are_packaged_without_staging_audio(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            staging = root / "staging"
            staging.mkdir()
            staging_manifest = staging / "all-manifest.jsonl"
            write_manifest(staging_manifest, staging)
            rows = [json.loads(line) for line in staging_manifest.read_text().splitlines()]
            corpus_a = root / "corpus-a"
            corpus_b = root / "corpus-b"
            manifests = []
            for corpus, selected in (
                (corpus_a, rows[::2]),
                (corpus_b, rows[1::2]),
            ):
                manifest = corpus / "manifest.jsonl"
                manifest.parent.mkdir(parents=True)
                manifest.write_text(
                    "".join(json.dumps(row, sort_keys=True) + "\n" for row in selected)
                )
                for row in selected:
                    source = staging / row["audio_path"]
                    destination = corpus / row["audio_path"]
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(source, destination)
                manifests.append(manifest)

            archive = root / "combined.tar.gz"
            report = BUILDER.prepare(
                manifests[0],
                corpus_a,
                root / "prepared",
                archive,
                BUILDER.FREEZE_TIMESTAMP,
                additional_corpora=[(manifests[1], corpus_b)],
            )

            self.assertEqual(report["filter"]["includedItemCount"], 15)
            self.assertEqual(len(report["inputs"]), 2)
            with tarfile.open(archive, "r:gz") as source:
                self.assertEqual(
                    len([name for name in source.getnames() if "/audio/" in name]),
                    15,
                )

    def test_base_split_report_keeps_existing_recordings_frozen(self) -> None:
        groups = [
            BUILDER.SourceGroup(
                identifier=f"en-source-{index}",
                language="en",
                recordings=(f"en-source-{index}",),
                speakers=(f"speaker-{index}",),
                duration_seconds=float(100 - index),
                item_count=10,
            )
            for index in range(14)
        ]
        groups.extend(
            BUILDER.SourceGroup(
                identifier=f"fr-source-{index}",
                language="fr",
                recordings=(f"fr-source-{index}",),
                speakers=(f"fr-speaker-{index}",),
                duration_seconds=10,
                item_count=1,
            )
            for index in range(3)
        )
        fixed = {
            "en-source-0": "train",
            "en-source-1": "validation",
            "en-source-2": "test",
        }

        assignments = BUILDER.assign_groups(groups, fixed)

        self.assertEqual(assignments["en-source-0"], "train")
        self.assertEqual(assignments["en-source-1"], "validation")
        self.assertEqual(assignments["en-source-2"], "test")
        self.assertEqual(set(assignments.values()), set(BUILDER.SPLITS))

    def test_group_cannot_join_two_frozen_splits(self) -> None:
        groups = [
            BUILDER.SourceGroup(
                identifier="joined",
                language="en",
                recordings=("old-train", "old-test"),
                speakers=("shared",),
                duration_seconds=10,
                item_count=1,
            ),
            BUILDER.SourceGroup(
                "validation", "en", ("validation",), ("v",), 10, 1
            ),
            BUILDER.SourceGroup("third", "en", ("third",), ("t",), 10, 1),
        ]
        with self.assertRaisesRegex(SystemExit, "crosses frozen base splits"):
            BUILDER.assign_groups(
                groups,
                {"old-train": "train", "old-test": "test"},
            )


if __name__ == "__main__":
    unittest.main()
