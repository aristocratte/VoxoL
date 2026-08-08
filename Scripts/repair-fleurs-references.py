#!/usr/bin/env python3
"""Rewrite FLEURS references in place after the column mapping was corrected.

The clean and verbatim fields were populated from the wrong TSV columns: the
field named "clean" held FLEURS' raw_transcription and vice versa. The two
differ only in casing and punctuation, both of which the scorer strips, so no
score moves — this is a correctness repair on the manifests, not a fix to a
wrong number.

Only the reference text changes. The sampled clips, their identifiers and their
audio bytes are untouched, so predictions already collected stay valid and only
the freeze and the scoring need to be redone.
"""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
import sys

LOCALES = {
    "en": "en_us",
    "fr": "fr_fr",
    "de": "de_de",
    "es": "es_419",
    "it": "it_it",
    "pt": "pt_br",
    "nl": "nl_nl",
    "pl": "pl_pl",
}


def references(tsv: Path) -> dict[str, tuple[str, str]]:
    """Map audio file name to (clean, verbatim)."""
    result = {}
    with tsv.open(encoding="utf-8", newline="") as stream:
        for columns in csv.reader(stream, delimiter="\t", quoting=csv.QUOTE_NONE):
            if len(columns) != 7:
                continue
            result[columns[1]] = (columns[3].strip(), columns[2].strip())
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    arguments = parser.parse_args()
    cache = arguments.root / "cache" / "fleurs"

    for language, locale in LOCALES.items():
        directory = arguments.root / "benchmarks" / f"fleurs-{language}"
        manifest_path = directory / "manifest-unfrozen.json"
        tsv = cache / f"{locale}-test.tsv"
        if not manifest_path.exists() or not tsv.exists():
            continue

        # The manifest keys on a hash of the upstream file name, so the mapping
        # back to a TSV row is rebuilt the same way the sampler built it.
        import hashlib

        by_identifier = {}
        for name, texts in references(tsv).items():
            identity = hashlib.sha256(
                f"fleurs\0{locale}\0{name}".encode()
            ).hexdigest()[:12]
            by_identifier[f"fleurs-{language}-{identity}"] = texts

        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        changed = 0
        for item in manifest["items"]:
            texts = by_identifier.get(item["id"])
            if texts is None:
                raise SystemExit(f"No upstream row for {item['id']}")
            clean, verbatim = texts
            if item["reference"]["clean"] != clean:
                changed += 1
            item["reference"]["clean"] = clean
            item["reference"]["verbatim"] = verbatim

        manifest_path.write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        # Everything downstream of the manifest is now stale.
        for stale in (
            "manifest-frozen.json",
            "voxol-report.json",
            "voxol-items.jsonl",
            "wispr-report.json",
            "wispr-items.jsonl",
        ):
            (directory / stale).unlink(missing_ok=True)
        print(f"fleurs-{language}: {changed}/{len(manifest['items'])} references rewritten")
    return 0


if __name__ == "__main__":
    sys.exit(main())
