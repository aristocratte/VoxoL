#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest
import zipfile


SCRIPT = Path(__file__).resolve().parents[2] / "Scripts" / "prepare-ami-meeting-benchmark.py"
SPEC = importlib.util.spec_from_file_location("prepare_ami_meeting_benchmark", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class AMIMeetingBenchmarkTests(unittest.TestCase):
    def test_words_are_sorted_and_chunked_at_speech_boundaries(self) -> None:
        xml_a = b'''<nite:root xmlns:nite="http://nite.sourceforge.net/">
          <w starttime="0.0" endtime="0.4">Hello</w>
          <w starttime="20.1" endtime="20.5">second</w>
          <w starttime="20.5" endtime="20.9">part</w>
        </nite:root>'''
        xml_b = b'''<nite:root xmlns:nite="http://nite.sourceforge.net/">
          <w starttime="0.2" endtime="0.6">there</w>
          <w starttime="0.6" endtime="0.6" punc="true">.</w>
        </nite:root>'''
        from io import BytesIO

        data = BytesIO()
        with zipfile.ZipFile(data, "w") as archive:
            archive.writestr("words/ES2004a.A.words.xml", xml_a)
            archive.writestr("words/ES2004a.B.words.xml", xml_b)
        data.seek(0)
        with zipfile.ZipFile(data) as archive:
            words = MODULE.annotation_words(archive, "ES2004a")
        self.assertEqual([word["text"] for word in words], ["Hello", "there", "second", "part"])
        self.assertEqual(len(MODULE.utterance_chunks(words)), 2)


if __name__ == "__main__":
    unittest.main()
