import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("build-polisher-suite-from-corpus.py")
SPEC = importlib.util.spec_from_file_location("build_polisher_suite", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(MODULE)


class PolisherSuiteCorpusTests(unittest.TestCase):
    def test_excludes_non_fr_en_rows(self):
        with tempfile.TemporaryDirectory() as temporary:
            corpus = Path(temporary) / "corpus.jsonl"
            rows = [
                {
                    "id": "fr",
                    "language": "fr",
                    "raw_transcript": "bonjour",
                    "target_text": "Bonjour.",
                },
                {
                    "id": "es",
                    "language": "es",
                    "raw_transcript": "hola",
                    "target_text": "Hola.",
                },
            ]
            corpus.write_text(
                "".join(json.dumps(row) + "\n" for row in rows),
                encoding="utf-8",
            )

            cases = MODULE.build_cases(corpus)

            self.assertEqual([case["id"] for case in cases], ["fr"])


if __name__ == "__main__":
    unittest.main()
