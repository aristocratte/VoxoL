#!/usr/bin/env python3
"""Can the polisher repair the words the recogniser was unsure about?

Per-word confidence says *where* the recogniser hesitated — flagging the least
certain fifth of the words catches over half the errors at two-in-three
precision. It does not say the language model knows *what* was meant.

This measures that, and the only number that matters is the balance between
two counts:

- **repairs** — a flagged word that was wrong and comes back right;
- **breaks** — a flagged word that was right and comes back wrong.

A dictation tool that fixes three words and corrupts four is worse than one
that changes nothing, so a positive balance is the whole bar. Words below the
flag threshold are never offered for change; that constraint is what separates
a repair pass from a rewriting one.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import sys

WORD = re.compile(r"[^\W\d_]+", re.UNICODE)

PROMPT = """Tu corriges une transcription vocale en {language}.

Les mots entre ⟪doubles chevrons⟫ ont été mal entendus par le système. Tous les
autres mots sont certains et ne doivent PAS changer.

Remplace chaque mot entre chevrons par ce que la personne a réellement dit,
en t'appuyant sur le sens de la phrase. Si un mot marqué te semble correct,
garde-le tel quel. N'ajoute rien, ne supprime rien, ne reformule pas.

Réponds uniquement par la phrase corrigée, sans chevrons et sans commentaire.

Phrase : {sentence}"""


def normalise(text: str) -> list[str]:
    return [w.lower() for w in WORD.findall(text.replace("’", "'"))]


def align(source: list[str], target: list[str]) -> list[int | None]:
    """Map each source position to the target position it became, or None.

    Comparing by index is what an earlier version of this did, and it silently
    produced a spectacular result: the moment the model adds or drops a word
    every later position shifts, so `honnête` was scored against `pas` and the
    mismatch counted as a repair. Nothing about a rewriting model guarantees
    the same word count, so the mapping has to be earned.
    """
    rows, columns = len(source) + 1, len(target) + 1
    cost = [[0] * columns for _ in range(rows)]
    for i in range(rows):
        cost[i][0] = i
    for j in range(columns):
        cost[0][j] = j
    for i in range(1, rows):
        for j in range(1, columns):
            cost[i][j] = min(
                cost[i - 1][j - 1] + (source[i - 1] != target[j - 1]),
                cost[i - 1][j] + 1,
                cost[i][j - 1] + 1,
            )
    mapping: list[int | None] = [None] * len(source)
    i, j = len(source), len(target)
    while i > 0 and j > 0:
        if cost[i][j] == cost[i - 1][j - 1] + (source[i - 1] != target[j - 1]):
            mapping[i - 1] = j - 1
            i, j = i - 1, j - 1
        elif cost[i][j] == cost[i - 1][j] + 1:
            i -= 1
        else:
            j -= 1
    return mapping


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--benchmark-root", type=Path, required=True)
    parser.add_argument("--benchmark", required=True)
    parser.add_argument("--confidences", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--language", default="français")
    parser.add_argument(
        "--percentile",
        type=float,
        default=20.0,
        help="Share of the least certain words offered for repair.",
    )
    parser.add_argument("--limit", type=int, default=80)
    parser.add_argument("--dump", type=Path)
    arguments = parser.parse_args()

    directory = arguments.benchmark_root / "benchmarks" / arguments.benchmark
    references = {
        item["id"]: item["reference"]["clean"]
        for item in json.loads(
            (directory / "manifest-frozen.json").read_text()
        )["items"]
    }
    confidences = {
        json.loads(line)["id"]: json.loads(line)["words"]
        for line in arguments.confidences.read_text().splitlines()
        if line.strip()
    }

    margins = sorted(
        word["margin"] for words in confidences.values() for word in words
    )
    if not margins:
        raise SystemExit("No confidences to work with.")
    threshold = margins[int(len(margins) * arguments.percentile / 100)]
    print(f"seuil de marge : {threshold:.2f} ({arguments.percentile:.0f}e centile)")

    from mlx_lm import load, generate

    model, tokenizer = load(str(arguments.model))

    # Only clips that actually have a flagged word are worth an inference.
    candidates = [
        identifier
        for identifier, words in confidences.items()
        if any(word["margin"] <= threshold for word in words)
    ]
    candidates.sort()
    candidates = candidates[: arguments.limit]

    repairs = breaks = untouched = 0
    examples = []
    for identifier in candidates:
        words = confidences[identifier]
        reference = set(normalise(references.get(identifier, "")))
        marked = " ".join(
            f"⟪{word['word']}⟫" if word["margin"] <= threshold else word["word"]
            for word in words
        )
        prompt = PROMPT.format(language=arguments.language, sentence=marked)
        messages = [{"role": "user", "content": prompt}]
        text = tokenizer.apply_chat_template(
            messages, add_generation_prompt=True, tokenize=False
        )
        answer = generate(model, tokenizer, prompt=text, max_tokens=120, verbose=False)
        produced = normalise(answer)
        # Words as the recogniser produced them, normalised the same way, so the
        # alignment compares like with like.
        original = [
            (normalise(word["word"]) or [""])[0] for word in words
        ]
        mapping = align(original, produced)

        for index, word in enumerate(words):
            if word["margin"] > threshold:
                continue
            before = original[index]
            if not before:
                continue
            position = mapping[index]
            after = produced[position] if position is not None else None
            was_right = before in reference
            now_right = after in reference if after else False
            if after is None or after == before:
                untouched += 1
            elif was_right and not now_right:
                breaks += 1
                if len(examples) < 8:
                    examples.append(("casse", before, after))
            elif not was_right and now_right:
                repairs += 1
                if len(examples) < 8:
                    examples.append(("repare", before, after))
        if arguments.dump:
            examples.append(("brut", marked[:100], answer.strip()[:100]))

    print(f"\nmots marques traites sur {len(candidates)} clips")
    print(f"  reparations : {repairs}")
    print(f"  casses      : {breaks}")
    print(f"  inchanges   : {untouched}")
    print(f"  bilan       : {repairs - breaks:+d}")
    print("\nexemples :")
    for kind, before, after in examples[:8]:
        print(f"  {kind:7s} {before}  ->  {after}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
