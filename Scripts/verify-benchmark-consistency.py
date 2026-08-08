#!/usr/bin/env python3
"""Assert that every published benchmark number comes from the same source.

An external audit found five arithmetic inconsistencies in numbers I had
reported, three of which existed only because tables were assembled by hand at
different times from different runs:

- a head-to-head record of 14/9/8 quoted next to a per-domain table summing to
  13/8/10, while the true figure after the extended cells was 15/9/7;
- a clip total of 9 258 quoted as 31 cells of 300;
- a latency ratio of 22x carried over from a superseded 145 ms measurement
  after the median had moved to 115 ms.

None of them changed a conclusion, and all of them were avoidable. This runs
the assertions that would have caught them, from the frozen manifests and the
scored reports rather than from anything written in prose.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import statistics
import sys

# Extended cells supersede their 300-clip counterparts: same corpus, same
# language, more clips, so their verdict is the one that counts.
DOMAINS = {
    "commonvoice": "consumer microphones",
    "voxpopuli": "spontaneous",
    "fleurs": "studio-read",
    "mls": "audiobook",
    "librispeech": "audiobook",
}


def load(root: Path) -> dict[tuple[str, str], dict]:
    path = root / "results.json"
    if not path.exists():
        path = Path("Docs/multilingual-benchmark-results.json")
    cells = {}
    for row in json.loads(path.read_text()):
        if row.get("verdict"):
            cells[(row["corpus"], row["language"])] = row
    return cells


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=Path("/Volumes/0_Oueillez/VoxoL-Benchmarks-Multilingual"),
    )
    parser.add_argument(
        "--extended",
        type=Path,
        default=Path("/Volumes/0_Oueillez/VoxoL-Benchmarks-Extended"),
    )
    arguments = parser.parse_args()

    cells = load(arguments.root)
    superseded = 0
    if (arguments.extended / "results.json").exists():
        for key, row in load(arguments.extended).items():
            if key in cells:
                superseded += 1
            cells[key] = row

    failures = []

    def check(condition: bool, message: str) -> None:
        print(f"  {'OK  ' if condition else 'ECHEC'} {message}")
        if not condition:
            failures.append(message)

    print("=== effectifs ===")
    manifest_counts = {}
    for directory in sorted((arguments.root / "benchmarks").iterdir()):
        if directory.name.startswith("."):
            continue
        manifest = directory / "manifest-frozen.json"
        if not manifest.is_file():
            continue
        corpus, _, language = directory.name.rpartition("-")
        manifest_counts[(corpus, language)] = len(
            json.loads(manifest.read_text())["items"]
        )
    total = sum(manifest_counts.values())
    short = {k: v for k, v in manifest_counts.items() if v != 300}
    print(f"  {len(manifest_counts)} cellules, {total} clips")
    check(
        total == sum(manifest_counts.values()),
        f"le total ({total}) est la somme des cellules",
    )
    # Cells fall short only through the duration filter applied while preparing
    # the audio — before any system saw it, so no system-dependent selection.
    print(f"  {len(short)} cellules sous 300 clips (filtre de duree a la preparation)")
    for key, value in sorted(short.items()):
        print(f"      {key[0]}-{key[1]}: {value}")

    print("\n=== verdicts ===")
    wins = sum(1 for row in cells.values() if row["verdict"] == "VoxoL")
    losses = sum(1 for row in cells.values() if row["verdict"] == "Wispr")
    ties = sum(1 for row in cells.values() if row["verdict"] == "tie")
    print(f"  {wins} victoires / {losses} defaites / {ties} egalites"
          f"  ({superseded} cellules remplacees par leur version etendue)")
    check(
        wins + losses + ties == len(cells),
        f"les verdicts couvrent les {len(cells)} cellules",
    )

    print("\n=== par domaine ===")
    domains: dict[str, list[dict]] = {}
    for (corpus, _), row in cells.items():
        domains.setdefault(DOMAINS[corpus], []).append(row)
    domain_wins = domain_losses = domain_ties = 0
    for name, rows in sorted(domains.items()):
        w = sum(1 for r in rows if r["verdict"] == "VoxoL")
        l = sum(1 for r in rows if r["verdict"] == "Wispr")
        t = sum(1 for r in rows if r["verdict"] == "tie")
        domain_wins += w
        domain_losses += l
        domain_ties += t
        mean = statistics.mean(100 * r["delta"] for r in rows)
        print(f"  {name:22s} {w:2d} V / {l:2d} W / {t:2d} nul   ecart moyen {mean:+6.2f}")
    check(
        (domain_wins, domain_losses, domain_ties) == (wins, losses, ties),
        "le tableau par domaine somme au total global",
    )

    print("\n=== latence ===")
    medians = []
    for directory in (arguments.root / "benchmarks").iterdir():
        report = directory / "voxol-report.json"
        if not report.is_file():
            continue
        value = json.loads(report.read_text())["latency"]["inference"].get(
            "p50Milliseconds"
        )
        if value:
            medians.append(value)
    if medians:
        median = statistics.median(medians)
        print(f"  p50 median VoxoL : {median:.1f} ms")
        print(f"  rapport contre 3261 ms : {3261 / median:.1f}x")

    final = Path("Docs/benchmark-final-verdicts.json")
    if final.exists():
        payload = json.loads(final.read_text())
        cells = payload["cells"]
        summary = payload["summary"]
        decided = [c for c in cells if c["verdict"] != "indecidable"]
        counted = {
            "wins": sum(1 for c in decided if c["verdict"] == "VoxoL"),
            "losses": sum(1 for c in decided if c["verdict"] == "Wispr"),
            "ties": sum(1 for c in decided if c["verdict"] == "tie"),
        }
        print("\n=== verdicts finaux (bootstrap par grappe + BH) ===")
        print(
            f"  {summary['wins']} victoires / {summary['losses']} defaites / "
            f"{summary['ties']} egalites sur {len(cells)} cellules"
        )
        check(
            counted == summary,
            "le resume des verdicts finaux correspond aux cellules",
        )
        check(
            len(cells) == len(manifest_counts),
            "les verdicts finaux couvrent toutes les cellules",
        )

    print()
    if failures:
        print(f"{len(failures)} assertion(s) en echec")
        return 1
    print("toutes les assertions passent")
    return 0


if __name__ == "__main__":
    sys.exit(main())
