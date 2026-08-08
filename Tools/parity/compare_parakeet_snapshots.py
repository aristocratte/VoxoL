#!/usr/bin/env python3
"""Compare source and Core ML Parakeet parity snapshots."""

from __future__ import annotations

import argparse
import json
import re
import unicodedata
from pathlib import Path

import numpy as np


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--coreml", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--quiet", action="store_true")
    parser.add_argument("--feature-max-absolute-error", type=float, default=1e-3)
    return parser.parse_args()


def load_snapshot(path: Path) -> tuple[dict[str, object], dict[str, np.ndarray]]:
    metadata = json.loads((path / "snapshot.json").read_text(encoding="utf-8"))
    tensors: dict[str, np.ndarray] = {}
    for item in metadata["tensors"]:
        dtype = np.dtype("<f4" if item["scalarType"] == "float32" else "<i4")
        values = np.fromfile(path / item["file"]["path"], dtype=dtype)
        tensors[item["name"]] = values.reshape(item["shape"])
    return metadata, tensors


def edit_distance(lhs: list[int], rhs: list[int]) -> int:
    previous = list(range(len(rhs) + 1))
    for lhs_index, lhs_value in enumerate(lhs):
        current = [lhs_index + 1]
        for rhs_index, rhs_value in enumerate(rhs):
            current.append(
                min(
                    current[-1] + 1,
                    previous[rhs_index + 1] + 1,
                    previous[rhs_index] + (lhs_value != rhs_value),
                )
            )
        previous = current
    return previous[-1]


def normalized_words(text: str) -> list[str]:
    canonical = unicodedata.normalize("NFC", text).casefold().replace("’", "'")
    return re.findall(r"[^\W_]+(?:'[^\W_]+)*|\d+(?:[.,]\d+)*", canonical)


def numeric_comparison(
    lhs: np.ndarray, rhs: np.ndarray
) -> dict[str, float | int | list[int] | None]:
    if lhs.shape != rhs.shape:
        return {"sourceShape": list(lhs.shape), "coreMLShape": list(rhs.shape)}
    lhs64 = lhs.astype(np.float64)
    rhs64 = rhs.astype(np.float64)
    lhs_non_finite = int((~np.isfinite(lhs64)).sum())
    rhs_non_finite = int((~np.isfinite(rhs64)).sum())
    if lhs_non_finite or rhs_non_finite:
        return {
            "sourceNonFiniteCount": lhs_non_finite,
            "coreMLNonFiniteCount": rhs_non_finite,
            "maximumAbsoluteError": None,
            "meanAbsoluteError": None,
            "normalizedRMSE": None,
            "cosineSimilarity": None,
        }
    difference = np.abs(lhs64 - rhs64)
    denominator = np.linalg.norm(lhs64)
    normalized_rmse = float(np.linalg.norm(difference) / denominator) if denominator else 0.0
    flattened_lhs = lhs64.ravel()
    flattened_rhs = rhs64.ravel()
    cosine_denominator = np.linalg.norm(flattened_lhs) * np.linalg.norm(flattened_rhs)
    cosine = (
        float(np.dot(flattened_lhs, flattened_rhs) / cosine_denominator)
        if cosine_denominator
        else 1.0
    )
    return {
        "maximumAbsoluteError": float(difference.max(initial=0)),
        "meanAbsoluteError": float(difference.mean()) if difference.size else 0.0,
        "normalizedRMSE": normalized_rmse,
        "cosineSimilarity": cosine,
    }


def masked_encoder_comparison(
    lhs: np.ndarray,
    rhs: np.ndarray,
    lhs_mask: np.ndarray,
    rhs_mask: np.ndarray,
) -> dict[str, float | int | list[int] | None]:
    if lhs.shape != rhs.shape or lhs.ndim != 3:
        return numeric_comparison(lhs, rhs)
    expected_mask_shape = lhs.shape[:2]
    if lhs_mask.shape != expected_mask_shape or rhs_mask.shape != expected_mask_shape:
        return numeric_comparison(lhs, rhs)
    valid_mask = lhs_mask.astype(bool) & rhs_mask.astype(bool)
    metrics = numeric_comparison(lhs[valid_mask], rhs[valid_mask])
    metrics["validFrameCount"] = int(valid_mask.sum())
    return metrics


def main() -> None:
    args = parse_args()
    source, source_tensors = load_snapshot(args.source)
    coreml, coreml_tensors = load_snapshot(args.coreml)
    if source["audioSHA256"] != coreml["audioSHA256"]:
        raise ValueError("Snapshots were produced from different audio bytes")

    feature_metrics = numeric_comparison(
        source_tensors["input_features"],
        coreml_tensors["input_features"],
    )
    unnormalized_feature_metrics = numeric_comparison(
        source_tensors["unnormalized_log_mel"],
        coreml_tensors["unnormalized_log_mel"],
    )
    audio_metrics = numeric_comparison(
        source_tensors["audio_samples"],
        coreml_tensors["audio_samples"],
    )
    power_metrics = (
        numeric_comparison(
            source_tensors["power_spectrogram"],
            coreml_tensors["power_spectrogram"],
        )
        if "power_spectrogram" in source_tensors
        and "power_spectrogram" in coreml_tensors
        else None
    )
    attention_mask_exact = np.array_equal(
        source_tensors["attention_mask"],
        coreml_tensors["attention_mask"],
    )
    encoder_mask_exact = np.array_equal(
        source_tensors["encoder_mask"],
        coreml_tensors["encoder_mask"],
    )
    encoder_all_frame_metrics = numeric_comparison(
        source_tensors["encoder_hidden"],
        coreml_tensors["encoder_hidden"],
    )
    encoder_metrics = masked_encoder_comparison(
        source_tensors["encoder_hidden"],
        coreml_tensors["encoder_hidden"],
        source_tensors["encoder_mask"],
        coreml_tensors["encoder_mask"],
    )
    source_tokens = source["tokenIDs"]
    coreml_tokens = coreml["tokenIDs"]
    token_distance = edit_distance(source_tokens, coreml_tokens)
    source_words = normalized_words(source["transcript"])
    coreml_words = normalized_words(coreml["transcript"])
    word_distance = edit_distance(source_words, coreml_words)
    first_decision_divergence = next(
        (
            index
            for index, (source_decision, coreml_decision) in enumerate(
                zip(source["decisions"], coreml["decisions"], strict=False)
            )
            if (
                source_decision["selectedTokenID"],
                source_decision["selectedDurationIndex"],
            )
            != (
                coreml_decision["selectedTokenID"],
                coreml_decision["selectedDurationIndex"],
            )
        ),
        None,
    )
    report = {
        "schemaVersion": 3,
        "audioSHA256": source["audioSHA256"],
        "sourceRuntime": source["runtime"],
        "coreMLRuntime": coreml["runtime"],
        "audioSamples": audio_metrics,
        "powerSpectrogram": power_metrics,
        "unnormalizedLogMel": unnormalized_feature_metrics,
        "inputFeatures": feature_metrics,
        "attentionMaskExact": attention_mask_exact,
        "encoderHidden": encoder_metrics,
        "encoderHiddenAllFrames": encoder_all_frame_metrics,
        "encoderMaskExact": encoder_mask_exact,
        "sourceTranscript": source["transcript"],
        "coreMLTranscript": coreml["transcript"],
        "transcriptExact": source["transcript"] == coreml["transcript"],
        "tokenEditDistance": token_distance,
        "tokenNormalizedEditDistance": token_distance / max(len(source_tokens), len(coreml_tokens), 1),
        "sourceToCoreMLWordErrorRate": word_distance / max(len(source_words), 1),
        "firstDecisionDivergence": first_decision_divergence,
        "sourceDecisionCount": len(source["decisions"]),
        "coreMLDecisionCount": len(coreml["decisions"]),
    }
    rendered = json.dumps(report, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered, encoding="utf-8")
    if not args.quiet:
        print(rendered, end="")

    feature_error = feature_metrics.get("maximumAbsoluteError")
    if (
        not attention_mask_exact
        or not isinstance(feature_error, (float, int))
        or feature_error > args.feature_max_absolute_error
    ):
        raise SystemExit(2)


if __name__ == "__main__":
    main()
