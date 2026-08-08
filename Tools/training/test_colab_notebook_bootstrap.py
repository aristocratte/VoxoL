#!/usr/bin/env python3
"""Regression tests for the generated Colab runtime bootstrap."""

from __future__ import annotations

import json
from pathlib import Path
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
NOTEBOOK_PATH = (
    REPOSITORY_ROOT / "Notebooks" / "VoxoL_Parakeet_Finetune_Colab.ipynb"
)


class ColabNotebookBootstrapTests(unittest.TestCase):
    def notebook_source(self) -> str:
        notebook = json.loads(NOTEBOOK_PATH.read_text(encoding="utf-8"))
        return "\n".join(
            "".join(cell.get("source", []))
            for cell in notebook["cells"]
        )

    def test_editable_nemo_checkout_is_visible_before_import(self) -> None:
        notebook = json.loads(NOTEBOOK_PATH.read_text(encoding="utf-8"))
        bootstrap = "".join(notebook["cells"][2]["source"])
        path_insertion = "sys.path.insert(0, str(NEMO_ROOT))"
        cache_invalidation = "importlib.invalidate_caches()"
        nemo_import = "import nemo"

        self.assertIn(path_insertion, bootstrap)
        self.assertIn(cache_invalidation, bootstrap)
        self.assertLess(bootstrap.index(path_insertion), bootstrap.index(nemo_import))
        self.assertLess(bootstrap.index(cache_invalidation), bootstrap.index(nemo_import))

    def test_training_checkpoints_stay_on_colab_scratch(self) -> None:
        source = self.notebook_source()

        self.assertIn(
            'local_experiment_root = SCRATCH_ROOT / "experiments"',
            source,
        )
        self.assertIn(
            'durable_candidate_root = DRIVE_ROOT / "candidates"',
            source,
        )
        self.assertIn(
            '"--experiment-root", attempt_experiment_root',
            source,
        )

    def test_training_candidate_is_streamed_to_drive(self) -> None:
        source = self.notebook_source()

        self.assertIn("def persist_candidate(source, destination):", source)
        self.assertIn("shutil.copyfileobj(source_file, destination_file", source)
        self.assertIn("candidate = persist_candidate(local_candidate", source)
        self.assertIn('rglob("*.delta.pt")', source)
        self.assertIn('f"{attempt[\'name\']}.delta.pt"', source)

    def test_sigkill_triggers_the_safe_training_profile(self) -> None:
        source = self.notebook_source()

        self.assertIn("return_code in (-9, 137)", source)

    def test_candidate_benchmark_reconstructs_base_model_from_delta(self) -> None:
        source = self.notebook_source()

        self.assertIn("2026-07-28-trainable-delta-v1", source)
        self.assertIn('("candidate", ["--delta", candidate])', source)


if __name__ == "__main__":
    unittest.main()
