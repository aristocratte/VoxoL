#!/usr/bin/env python3
"""Would a language model in the decoder have fixed these errors?

Adding shallow LM fusion to the decoder is days of work: an n-gram over the
subword vocabulary, a prefix-conditioned scorer in the Swift decode loop, a
weight to tune per language. Worth doing only if the language model would
actually prefer the right answer.

That is measurable now, without building any of it. On the clips where VoxoL
erred and Wispr did not, score both the human reference and VoxoL's transcript
under a language model. If the reference is consistently the more probable of
the two, fusion has headroom — the acoustic model offered a worse continuation
and a language model would have pushed back. If the model likes VoxoL's version
as much or better, no amount of fusion helps and the gap is acoustic.

Uses the polisher already installed on the machine, so nothing is downloaded
and nothing new has to be trusted.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import statistics
import sys


def load_predictions(path: Path) -> dict[str, str]:
    return {
        json.loads(line)["id"]: json.loads(line)["finalText"]
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    }


def load_errors(path: Path) -> dict[str, int]:
    result = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        counts = row["finalWordErrors"]
        result[row["id"]] = (
            counts["substitutions"] + counts["deletions"] + counts["insertions"]
        )
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--benchmark", action="append", required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--limit", type=int, default=120)
    arguments = parser.parse_args()

    import mlx.core as mx
    from mlx_lm import load

    model, tokenizer = load(str(arguments.model))

    def average_logprob(text: str) -> float | None:
        """Mean per-token log-probability, so length does not decide."""
        ids = tokenizer.encode(text)
        if len(ids) < 2:
            return None
        tokens = mx.array([ids])
        logits = model(tokens[:, :-1])
        logprobs = logits - mx.logsumexp(logits, axis=-1, keepdims=True)
        targets = tokens[:, 1:]
        picked = mx.take_along_axis(logprobs, targets[..., None], axis=-1)
        return float(mx.mean(picked).item())

    for name in arguments.benchmark:
        directory = arguments.root / "benchmarks" / name
        manifest = directory / "manifest-numeric-frozen.json"
        if not manifest.is_file():
            print(f"{name}: absent")
            continue
        references = {
            item["id"]: item["reference"]["clean"]
            for item in json.loads(manifest.read_text())["items"]
        }
        voxol = load_predictions(directory / "voxol-numeric-predictions.jsonl")
        our_errors = load_errors(directory / "voxol-numeric-items.jsonl")
        their_errors = load_errors(directory / "wispr-numeric-items.jsonl")

        # Only clips VoxoL lost: a clip both systems got right says nothing.
        candidates = [
            identifier
            for identifier in references
            if our_errors.get(identifier, 0) > their_errors.get(identifier, 0)
        ]
        candidates.sort()
        candidates = candidates[: arguments.limit]

        prefers_reference = 0
        margins = []
        for identifier in candidates:
            reference = references[identifier]
            hypothesis = voxol.get(identifier, "")
            if not hypothesis.strip():
                continue
            reference_score = average_logprob(reference)
            hypothesis_score = average_logprob(hypothesis)
            if reference_score is None or hypothesis_score is None:
                continue
            margins.append(reference_score - hypothesis_score)
            if reference_score > hypothesis_score:
                prefers_reference += 1

        if not margins:
            print(f"{name}: aucun clip comparable")
            continue
        share = 100 * prefers_reference / len(margins)
        print(
            f"{name:16s} {len(margins):4d} clips perdus  "
            f"le LM prefere la reference dans {share:5.1f}%  "
            f"marge mediane {statistics.median(margins):+.4f}"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
