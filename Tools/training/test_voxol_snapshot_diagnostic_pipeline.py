#!/usr/bin/env python3
"""Tests for VoxoL's no-training snapshot diagnostic pipeline."""

from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY_ROOT))
SCRIPT = Path(__file__).with_name("run_voxol_snapshot_diagnostic_pipeline.py")
SPEC = importlib.util.spec_from_file_location(
    "run_voxol_snapshot_diagnostic_pipeline",
    SCRIPT,
)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class SnapshotDiagnosticPipelineTests(unittest.TestCase):
    def test_extracts_and_reuses_a_verified_research_archive(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive_path = root / "research.zip"
            payload = b"candidate"
            payload_digest = hashlib.sha256(payload).hexdigest()
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("VoxoL-Parakeet/candidates/candidate.pt", payload)
                archive.writestr(
                    "VoxoL-Parakeet/SHA256SUMS.txt",
                    (
                        f"{payload_digest}  "
                        "VoxoL-Parakeet/candidates/candidate.pt\n"
                    ),
                )

            extracted = MODULE.extract_research_archive(
                archive_path,
                digest(archive_path),
                root / "work",
            )
            reused = MODULE.extract_research_archive(
                archive_path,
                digest(archive_path),
                root / "work",
            )

            self.assertEqual(extracted, reused)
            self.assertEqual(
                (extracted / "candidates" / "candidate.pt").read_bytes(),
                payload,
            )

    def test_rejects_an_unsafe_research_archive_path(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive_path = root / "unsafe.zip"
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("../outside", b"unsafe")

            with self.assertRaisesRegex(RuntimeError, "Unsafe"):
                MODULE.extract_research_archive(
                    archive_path,
                    digest(archive_path),
                    root / "work",
                )

    def test_resolves_candidate_and_archived_prediction_paths(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            candidate = root / "candidates" / "candidate.delta.pt"
            candidate.parent.mkdir(parents=True)
            candidate.write_bytes(b"candidate")
            candidate_digest = digest(candidate)
            (candidate.parent / "training-complete.json").write_text(
                json.dumps(
                    {
                        "candidate": "/remote/candidate.delta.pt",
                        "sha256": candidate_digest,
                    }
                ),
                encoding="utf-8",
            )
            evaluation = root / "results" / "evaluation"
            baseline = (
                evaluation
                / "baseline"
                / "wispr-teacher-heldout-predictions.jsonl"
            )
            selected = (
                evaluation
                / f"candidate-{candidate_digest[:12]}"
                / "wispr-teacher-heldout-predictions.jsonl"
            )
            baseline.parent.mkdir(parents=True)
            selected.parent.mkdir(parents=True)
            baseline.write_text("{}\n", encoding="utf-8")
            selected.write_text("{}\n", encoding="utf-8")

            paths = MODULE.archived_candidate_paths(root)

            self.assertEqual(paths["snapshot"], candidate)
            self.assertEqual(paths["baselineTeacher"], baseline)
            self.assertEqual(paths["candidateTeacher"], selected)


if __name__ == "__main__":
    unittest.main()
