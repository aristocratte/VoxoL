#!/usr/bin/env python3
"""Score a second time with every number written the same way on both sides.

Wispr Flow writes numbers as digits — "598 route de Clisson" — and VoxoL spells
them out, which is also how Common Voice writes its reference sentences. The
scorer strips punctuation but has no idea that "598" and "cinq cent
quatre-vingt-dix-huit" are the same thing, so on a corpus full of addresses
that convention difference alone cost Wispr several points. Publishing that as
a recognition result would be wrong.

This expands every integer to words, in the benchmark's own language, on the
reference and on both systems' transcripts alike. Applied symmetrically, any
quirk of the expander cancels: what remains is disagreement about what was
said, not about how to write it.

The original scoring is kept. Both belong in the report — the verbatim one
because it is what a corpus's published protocol measures, and this one because
it is what the difference between two recognisers actually is.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

from num2words import num2words

LANGUAGE_CODES = {
    "english": "en",
    "french": "fr",
    "german": "de",
    "spanish": "es",
    "italian": "it",
    "portuguese": "pt",
    "dutch": "nl",
    "polish": "pl",
}

# "30 500" and "30 500" are one number written with a thousands separator; the
# groups are joined before expansion so it does not become "thirty" "five
# hundred".
GROUPED = re.compile(r"(?<!\d)(\d{1,3})((?:[    ]\d{3})+)(?!\d)")
INTEGER = re.compile(r"\d+")
# Above this the expansions stop being anything a person would say, and a long
# digit string is an identifier rather than a quantity.
MAXIMUM_EXPANDED = 10**12


def expand(text: str, language: str) -> str:
    if not text:
        return text
    text = GROUPED.sub(lambda m: m.group(1) + re.sub(r"\D", "", m.group(2)), text)

    def replace(match: re.Match[str]) -> str:
        value = int(match.group())
        if value >= MAXIMUM_EXPANDED:
            return match.group()
        try:
            return f" {num2words(value, lang=language)} "
        except (NotImplementedError, OverflowError):
            return match.group()

    return re.sub(r"\s+", " ", INTEGER.sub(replace, text)).strip()


def rewrite_predictions(source: Path, destination: Path, language: str) -> None:
    rows = []
    for line in source.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        row["rawText"] = expand(row.get("rawText") or "", language)
        row["finalText"] = expand(row.get("finalText") or "", language)
        rows.append(row)
    destination.write_text(
        "".join(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n" for row in rows),
        encoding="utf-8",
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--cli", type=Path, required=True)
    parser.add_argument(
        "--benchmark",
        action="append",
        help="Limit to these benchmark directory names. Repeatable.",
    )
    arguments = parser.parse_args()

    for directory in sorted((arguments.root / "benchmarks").iterdir()):
        if directory.name.startswith(".") or not (
            directory / "manifest-frozen.json"
        ).is_file():
            continue
        if arguments.benchmark and directory.name not in arguments.benchmark:
            continue
        systems = [
            system
            for system in ("voxol", "wispr")
            if (directory / f"{system}-predictions.jsonl").exists()
        ]
        if not systems:
            continue

        manifest = json.loads((directory / "manifest-frozen.json").read_text())
        language = LANGUAGE_CODES[manifest["items"][0]["language"]]
        for item in manifest["items"]:
            item["reference"]["clean"] = expand(item["reference"]["clean"], language)
            item["reference"]["verbatim"] = expand(
                item["reference"]["verbatim"], language
            )
        # Re-freezing recomputes the content hash over the same untouched audio,
        # so the derived benchmark is a first-class frozen manifest rather than
        # an edited one wearing someone else's hash.
        for stale in ("manifest-numeric.json", "manifest-numeric-frozen.json"):
            (directory / stale).unlink(missing_ok=True)
        (directory / "manifest-numeric.json").write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        subprocess.run(
            [
                str(arguments.cli),
                "freeze",
                "--manifest",
                str(directory / "manifest-numeric.json"),
                "--audio-root",
                str(directory / "audio"),
                "--output",
                str(directory / "manifest-numeric-frozen.json"),
            ],
            check=True,
            capture_output=True,
        )

        summary = []
        for system in systems:
            for stale in (
                f"{system}-numeric-predictions.jsonl",
                f"{system}-numeric-report.json",
                f"{system}-numeric-items.jsonl",
            ):
                (directory / stale).unlink(missing_ok=True)
            rewrite_predictions(
                directory / f"{system}-predictions.jsonl",
                directory / f"{system}-numeric-predictions.jsonl",
                language,
            )
            subprocess.run(
                [
                    str(arguments.cli),
                    "score",
                    "--manifest",
                    str(directory / "manifest-numeric-frozen.json"),
                    "--predictions",
                    str(directory / f"{system}-numeric-predictions.jsonl"),
                    "--output",
                    str(directory / f"{system}-numeric-report.json"),
                    "--per-item",
                    str(directory / f"{system}-numeric-items.jsonl"),
                ],
                check=True,
                capture_output=True,
            )
            counts = json.loads(
                (directory / f"{system}-numeric-report.json").read_text()
            )["finalClean"]["wordErrors"]
            rate = (
                100
                * (counts["substitutions"] + counts["deletions"] + counts["insertions"])
                / counts["referenceUnitCount"]
            )
            summary.append(f"{system} {rate:.2f}%")
        print(f"  {directory.name:20s} {'  '.join(summary)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
