#!/usr/bin/env python3
"""Tests for lossless compact polisher edits."""

from __future__ import annotations

import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).parent))
from compact_polisher_edits import apply_compact_edits, encode_compact_edits


class CompactPolisherEditTests(unittest.TestCase):
    def test_noop_uses_empty_edit_list(self) -> None:
        payload = encode_compact_edits("Keep this.", "Keep this.")

        self.assertEqual(payload, "[]")
        self.assertEqual(apply_compact_edits("Keep this.", payload), "Keep this.")

    def test_reconstructs_separated_edits_and_unicode(self) -> None:
        source = "euh bonjour camille le rapport est pret"
        target = "Bonjour Camille, le rapport est prêt."

        payload = encode_compact_edits(source, target)

        self.assertEqual(apply_compact_edits(source, payload), target)
        self.assertGreater(len(json.loads(payload)), 1)

    def test_repeated_anchor_is_expanded_until_unique(self) -> None:
        source = "test one and test two"
        target = "Test one and test two."

        payload = encode_compact_edits(source, target)

        self.assertEqual(apply_compact_edits(source, payload), target)

    def test_invalid_or_ambiguous_edits_fail_closed(self) -> None:
        with self.assertRaises(ValueError):
            apply_compact_edits(
                "repeat repeat",
                json.dumps([["repeat", "Repeat"]]),
            )
        with self.assertRaises(ValueError):
            apply_compact_edits("text", '{"edits":[]}')


if __name__ == "__main__":
    unittest.main()
