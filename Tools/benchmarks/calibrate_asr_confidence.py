#!/usr/bin/env python3
"""Fit and evaluate VoxoL's content-free ASR risk model on frozen splits."""

from __future__ import annotations

import argparse
import json
import math
import re
import unicodedata
from pathlib import Path

import numpy as np


FEATURE_NAMES = [
    "logEmittedTokenCount",
    "meanTokenLogitMargin",
    "lowerDecileTokenLogitMargin",
    "meanDurationLogitMargin",
    "lowerDecileDurationLogitMargin",
    "blankDecisionRatio",
    "logMaximumFramesWithoutEmission",
    "minimumOverlapTokenAgreement",
    "usedFallbackSegmentation",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--predictions", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--l2", type=float, default=1.0)
    return parser.parse_args()


def normalize(text: str) -> list[str]:
    canonical = unicodedata.normalize("NFC", text).casefold().replace("’", "'")
    canonical = re.sub(r"[^\w\d']+", " ", canonical, flags=re.UNICODE)
    return canonical.strip().split()


def edit_distance(reference: list[str], hypothesis: list[str]) -> int:
    previous = list(range(len(hypothesis) + 1))
    for index, word in enumerate(reference):
        current = [index + 1]
        for other_index, other_word in enumerate(hypothesis):
            current.append(
                min(
                    previous[other_index + 1] + 1,
                    current[other_index] + 1,
                    previous[other_index] + (word != other_word),
                )
            )
        previous = current
    return previous[-1]


def contains_phrase(hypothesis: list[str], phrase: list[str]) -> bool:
    if not phrase or len(phrase) > len(hypothesis):
        return False
    return any(
        hypothesis[start : start + len(phrase)] == phrase
        for start in range(len(hypothesis) - len(phrase) + 1)
    )


def features(confidence: dict[str, object]) -> list[float]:
    overlap = confidence.get("minimumOverlapTokenAgreement")
    return [
        math.log1p(float(confidence["emittedTokenCount"])),
        float(confidence["meanTokenLogitMargin"]),
        float(confidence["lowerDecileTokenLogitMargin"]),
        float(confidence["meanDurationLogitMargin"]),
        float(confidence["lowerDecileDurationLogitMargin"]),
        float(confidence["blankDecisionRatio"]),
        math.log1p(float(confidence["maximumFramesWithoutEmission"])),
        float(overlap) if overlap is not None else -1.0,
        float(bool(confidence["usedFallbackSegmentation"])),
    ]


def sigmoid(values: np.ndarray) -> np.ndarray:
    return 1 / (1 + np.exp(-np.clip(values, -30, 30)))


def fit_logistic(
    matrix: np.ndarray,
    labels: np.ndarray,
    l2: float,
) -> np.ndarray:
    design = np.column_stack([np.ones(len(matrix)), matrix])
    weights = np.zeros(design.shape[1], dtype=np.float64)
    penalty = np.eye(design.shape[1], dtype=np.float64) * l2
    penalty[0, 0] = 0
    for _ in range(100):
        probabilities = sigmoid(design @ weights)
        variance = np.maximum(probabilities * (1 - probabilities), 1e-6)
        gradient = design.T @ (probabilities - labels) + penalty @ weights
        hessian = (design.T * variance) @ design + penalty
        step = np.linalg.solve(hessian, gradient)
        weights -= step
        if np.linalg.norm(step) < 1e-8:
            break
    return weights


def average_precision(labels: np.ndarray, probabilities: np.ndarray) -> float:
    positives = int(labels.sum())
    if positives == 0:
        return 0.0
    order = np.argsort(-probabilities)
    ordered = labels[order]
    precision = np.cumsum(ordered) / np.arange(1, len(ordered) + 1)
    return float((precision * ordered).sum() / positives)


def metrics(labels: np.ndarray, probabilities: np.ndarray) -> dict[str, object]:
    if len(labels) == 0:
        return {"count": 0}
    clipped = np.clip(probabilities, 1e-8, 1 - 1e-8)
    bins = np.minimum((probabilities * 10).astype(int), 9)
    ece = 0.0
    for bucket in range(10):
        selected = bins == bucket
        if selected.any():
            ece += float(selected.mean()) * abs(
                float(probabilities[selected].mean())
                - float(labels[selected].mean())
            )
    return {
        "count": len(labels),
        "badCount": int(labels.sum()),
        "badRate": float(labels.mean()),
        "brierScore": float(np.mean((probabilities - labels) ** 2)),
        "negativeLogLikelihood": float(
            -np.mean(labels * np.log(clipped) + (1 - labels) * np.log(1 - clipped))
        ),
        "expectedCalibrationError10Bins": ece,
        "areaUnderPrecisionRecall": average_precision(labels, probabilities),
    }


def best_f1_threshold(
    labels: np.ndarray,
    probabilities: np.ndarray,
) -> dict[str, float] | None:
    if len(labels) == 0 or labels.sum() == 0:
        return None
    best: dict[str, float] | None = None
    for threshold in sorted(set(float(value) for value in probabilities)):
        predicted = probabilities >= threshold
        true_positive = int((predicted & (labels == 1)).sum())
        false_positive = int((predicted & (labels == 0)).sum())
        false_negative = int(((~predicted) & (labels == 1)).sum())
        precision = true_positive / max(true_positive + false_positive, 1)
        recall = true_positive / max(true_positive + false_negative, 1)
        f1 = 2 * precision * recall / max(precision + recall, 1e-12)
        candidate = {
            "threshold": threshold,
            "precision": precision,
            "recall": recall,
            "f1": f1,
        }
        if best is None or candidate["f1"] > best["f1"]:
            best = candidate
    return best


def main() -> None:
    args = parse_args()
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    if not manifest.get("frozenAt") or not manifest.get("contentSHA256"):
        raise ValueError("Confidence calibration requires a frozen manifest")
    items = {str(item["id"]): item for item in manifest["items"]}
    predictions = [
        json.loads(line)
        for line in args.predictions.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]

    rows: list[tuple[str, list[float], int]] = []
    for prediction in predictions:
        item = items.get(str(prediction["id"]))
        confidence = prediction.get("confidence")
        if item is None or confidence is None:
            continue
        reference = normalize(item["reference"]["verbatim"])
        hypothesis = normalize(prediction["rawText"])
        word_error_rate = edit_distance(reference, hypothesis) / max(len(reference), 1)
        critical_error = any(
            not any(
                contains_phrase(hypothesis, normalize(alternative))
                for alternative in [span["expected"]]
                + span.get("acceptedAlternatives", [])
            )
            for span in item["reference"].get("criticalSpans", [])
        )
        label = int(word_error_rate > 0.10 or critical_error)
        rows.append((item["split"], features(confidence), label))

    development = [row for row in rows if row[0] == "development"]
    if len(development) < 20 or len({row[2] for row in development}) != 2:
        raise ValueError(
            "Need at least 20 development rows containing both good and bad outputs"
        )
    development_matrix = np.array([row[1] for row in development], dtype=np.float64)
    labels = np.array([row[2] for row in development], dtype=np.float64)
    means = development_matrix.mean(axis=0)
    scales = development_matrix.std(axis=0)
    scales[scales < 1e-8] = 1
    weights = fit_logistic((development_matrix - means) / scales, labels, args.l2)

    split_reports: dict[str, object] = {}
    split_probabilities: dict[str, tuple[np.ndarray, np.ndarray]] = {}
    for split in ("development", "calibration", "blind", "stress"):
        selected = [row for row in rows if row[0] == split]
        if not selected:
            split_reports[split] = {"count": 0}
            continue
        matrix = np.array([row[1] for row in selected], dtype=np.float64)
        split_labels = np.array([row[2] for row in selected], dtype=np.float64)
        probabilities = sigmoid(
            weights[0] + ((matrix - means) / scales) @ weights[1:]
        )
        split_probabilities[split] = (split_labels, probabilities)
        split_reports[split] = metrics(split_labels, probabilities)

    calibration = split_probabilities.get("calibration")
    threshold = (
        best_f1_threshold(*calibration)
        if calibration is not None
        else None
    )
    calibration_count = int(split_reports["calibration"]["count"])
    output = {
        "schemaVersion": 1,
        "manifestSHA256": manifest["contentSHA256"],
        "target": "WER>0.10-or-critical-span-error",
        "featureNames": FEATURE_NAMES,
        "standardizationMean": means.tolist(),
        "standardizationScale": scales.tolist(),
        "intercept": float(weights[0]),
        "coefficients": weights[1:].tolist(),
        "l2": args.l2,
        "splits": split_reports,
        "calibrationBestF1Threshold": threshold,
        "promotionAllowed": calibration_count >= 200
        and int(split_reports["blind"]["count"]) >= 700,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(output, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(args.output)


if __name__ == "__main__":
    main()
