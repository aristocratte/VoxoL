"""Separate text-only AI reference review from acoustic or human approval.

This diagnostic format deliberately cannot satisfy the existing human training
gate. Unknown teacher revision and AI-derived verbatim remain explicit limits.
"""
from __future__ import annotations

import argparse
from collections import Counter
import copy
import hashlib
import json
from pathlib import Path

import dictation_campaign as c

REVIEW_PROMPT = """Create a faithful written version from this historical AI verbatim only.
Preserve all substantive words, names, numbers and their roles, negation, uncertainty,
questions, requested actions, technical identifiers and code. Fix only clearly
supported spelling, agreement, punctuation and redundant fillers. Do not summarize,
answer the request, invent inaudible words, or turn uncertainty into a fact. Exclude
ambiguous or unintelligible cases with a specific reason. This is text-only AI review,
not audio verification, human review, a blind acoustic reference or training approval.
Do not consult model predictions or the previous mixed-intent faithful target.
"""


def sha_text(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


def prepare(manifest: dict) -> tuple[dict, dict]:
    c.validate(manifest)
    selected = c.select(manifest, "diagnostic")
    inputs = []
    edit_ratios = []
    for item in selected:
        verbatim = item["references"]["verbatim"]["text"]
        faithful = item["references"]["faithful"]["text"]
        edits = c.edit_counts(c.words(verbatim), c.words(faithful))
        ratio = edits["errors"] / max(1, edits["referenceWords"])
        edit_ratios.append(ratio)
        inputs.append({"id": item["id"], "sourceGroup": item["sourceGroup"],
                       "audioSHA256": item["audio"]["sha256"], "sourceItemSHA256": item["itemSHA256"],
                       "verbatim": verbatim, "verbatimSHA256": sha_text(verbatim),
                       "parentProvenance": item["references"]["verbatim"]["provenance"]["kind"]})
    common = {"schemaVersion": "voxol-ai-text-reference-review-v2", "sourceManifestSHA256": manifest["manifestSHA256"],
              "prompt": REVIEW_PROMPT, "promptSHA256": sha_text(REVIEW_PROMPT),
              "allowedUse": "diagnostic-regression-only", "trainingEligible": False,
              "audioReviewed": False, "humanReviewed": False,
              "teacher": {"model": "GPT-6 Astra Pro (ChatGPT reported identity)", "providerRevision": None},
              "limitations": ["historical verbatim was AI-derived", "no audio was reviewed by the text reviewer",
                              "teacher backend revision is unavailable; annotation content, not generation, is reproducible",
                              "no acoustic accuracy gain can be inferred from a reference change"]}
    audit = {"sourceManifestSHA256": manifest["manifestSHA256"], "diagnosticCases": len(inputs),
             "lexicallyDifferentLegacyTargets": sum(r > 0 for r in edit_ratios),
             "legacyTargetsAbove20PercentEdits": sum(r > .2 for r in edit_ratios),
             "interpretation": "Edit distance is an audit alert, not a semantic classification of intent.",
             "reservedCasesUntouched": sum(i["decision"] == "reserved" for i in manifest["items"])}
    return {**common, "items": inputs}, audit


def apply_reviews(inputs: dict, reviews: list[dict]) -> dict:
    expected = {item["id"]: item for item in inputs["items"]}
    seen = set()
    output = []
    for review in reviews:
        identifier = review["id"]
        if identifier not in expected or identifier in seen:
            raise ValueError("Unknown or duplicate reviewed ID")
        seen.add(identifier)
        source = expected[identifier]
        if review.get("verbatimSHA256") != source["verbatimSHA256"]:
            raise ValueError("Review does not bind the original verbatim")
        decision = review.get("decision")
        if decision not in ("accepted", "excluded") or not review.get("reason"):
            raise ValueError("Each review needs a decision and an explicit reason")
        text = review.get("faithfulText")
        if decision == "accepted":
            if not isinstance(text, str) or not text.strip():
                raise ValueError("Accepted faithful reference cannot be empty")
            if c.NUMBER.findall(text) != c.NUMBER.findall(source["verbatim"]):
                if not review.get("numericJustification"):
                    raise ValueError("A changed literal number sequence requires a reviewed explanation")
            if c.NEGATION.findall(text.casefold()) != c.NEGATION.findall(source["verbatim"].casefold()):
                if not review.get("negationJustification"):
                    raise ValueError("A changed literal negation sequence requires a reviewed explanation")
        elif text is not None:
            raise ValueError("Excluded case must not retain a target usable as a reference")
        output.append({**source, "decision": decision, "faithfulText": text,
                       "faithfulSHA256": sha_text(text) if text is not None else None,
                       "reason": review["reason"], "numericJustification": review.get("numericJustification"),
                       "negationJustification": review.get("negationJustification"),
                       "rewriteText": None, "codeTarget": None,
                       "reviewKind": "ai-text-only", "humanReviewed": False, "trainingEligible": False})
    if seen != set(expected):
        raise ValueError("Every diagnostic item must be reviewed or explicitly excluded")
    result = {k: copy.deepcopy(v) for k, v in inputs.items() if k != "items"}
    result["items"] = output
    result["referenceSetSHA256"] = c.digest(result)
    return result


def score_existing(reviewed: dict, manifest: dict, run_directory: Path) -> dict:
    original_items = c.select(manifest, "diagnostic")
    run = json.loads((run_directory / "run.json").read_text())
    if run["manifestSHA256"] != reviewed["sourceManifestSHA256"]:
        raise ValueError("Predictions come from another source campaign")
    found = c.validate_results(c.read_jsonl(run_directory / "predictions.jsonl"), original_items, run)
    rows = []
    for item in reviewed["items"]:
        if item["decision"] == "excluded":
            continue
        prediction = found.get(item["id"], {})
        text = prediction.get("finalText", "")
        rows.append({"id": item["id"], **c.edit_counts(c.words(item["faithfulText"]), c.words(text)),
                     "failure": bool(prediction.get("failure")) or prediction.get("status") != "ok",
                     "numericAlert": c.NUMBER.findall(text) != c.NUMBER.findall(item["faithfulText"]),
                     "negationAlert": c.NEGATION.findall(text.casefold()) != c.NEGATION.findall(item["faithfulText"].casefold())})
    total = {key: sum(row[key] for row in rows) for key in ("errors", "referenceWords", "substitutions", "deletions", "insertions")}
    return {"schemaVersion": 1, "referenceSetSHA256": reviewed["referenceSetSHA256"],
            "originalPredictionsSHA256": c.file_digest(run_directory / "predictions.jsonl"),
            "cases": len(rows), "excluded": len(reviewed["items"]) - len(rows),
            "wordErrorRate": total["errors"] / total["referenceWords"] if total["referenceWords"] else None,
            **total, "generationFailures": sum(row["failure"] for row in rows),
            "numericAlerts": sum(row["numericAlert"] for row in rows),
            "negationAlerts": sum(row["negationAlert"] for row in rows), "rows": rows,
            "accuracyGainDemonstrated": False,
            "interpretation": "Same archived output under repaired text-only reference contract; not an application or acoustic improvement."}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--reviews", type=Path)
    parser.add_argument("--processor-run", type=Path)
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    inputs, audit = prepare(manifest)
    args.output.mkdir(parents=True, exist_ok=False)
    c.write_json(args.output / "legacy-audit.json", audit)
    if args.reviews is None:
        c.write_json(args.output / "review-inputs.json", inputs)
        print(json.dumps(audit))
        return
    reviewed = apply_reviews(inputs, json.loads(args.reviews.read_text()))
    c.write_json(args.output / "references.v2.json", reviewed)
    if args.processor_run:
        scored = score_existing(reviewed, manifest, args.processor_run)
        c.write_json(args.output / "same-output-new-contract-score.json", scored)
        print(json.dumps({k: v for k, v in scored.items() if k != "rows"}))


if __name__ == "__main__":
    main()
