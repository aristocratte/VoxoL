#!/usr/bin/env python3
"""Run a resumable, duration-stratified Parakeet source/Core ML parity suite."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path


MAX_FIXED_WINDOW_DURATION_SECONDS = 479_840 / 16_000


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--audio-root", type=Path, required=True)
    parser.add_argument("--source-model", required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--source-cache-dir", type=Path)
    parser.add_argument("--source-delta", type=Path)
    parser.add_argument("--expected-source-delta-sha256")
    parser.add_argument("--coreml-model-root", type=Path, required=True)
    parser.add_argument("--coreml-cli", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--compute-units", choices=("all", "gpu", "ane", "cpu"), default="gpu")
    parser.add_argument("--source-compatible-features", action="store_true")
    parser.add_argument("--limit", type=int, default=30)
    return parser.parse_args()


def read_jsonl(path: Path) -> list[dict[str, object]]:
    return [
        json.loads(line)
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]


def select_items(
    rows: list[dict[str, object]],
    limit: int,
) -> list[dict[str, object]]:
    eligible = [
        row
        for row in rows
        if 0.1
        <= float(row.get("audioDurationSeconds") or row.get("duration") or 0)
        <= MAX_FIXED_WINDOW_DURATION_SECONDS
    ]
    eligible.sort(
        key=lambda row: (
            float(row.get("audioDurationSeconds") or row.get("duration") or 0),
            str(row["id"]),
        )
    )
    if len(eligible) <= limit:
        return eligible
    indices = {
        round(position * (len(eligible) - 1) / (limit - 1))
        for position in range(limit)
    }
    return [eligible[index] for index in sorted(indices)]


def run(command: list[str], allow_comparison_failure: bool = False) -> None:
    completed = subprocess.run(command, check=False)
    if completed.returncode and not (allow_comparison_failure and completed.returncode == 2):
        raise subprocess.CalledProcessError(completed.returncode, command)


def resolve_audio_path(audio_root: Path, relative_path: str) -> Path:
    direct = audio_root / relative_path
    if direct.is_file():
        return direct
    parts = Path(relative_path).parts
    if len(parts) >= 3 and parts[0] == "audio":
        session = parts[1]
        filename = Path(*parts[2:])
        alternatives = (
            audio_root / "records" / session / "audio" / filename,
            audio_root / session / "audio" / filename,
        )
        for alternative in alternatives:
            if alternative.is_file():
                return alternative
    raise FileNotFoundError(f"Missing parity audio: {direct}")


def main() -> None:
    args = parse_args()
    if (args.source_delta is None) != (args.expected_source_delta_sha256 is None):
        raise ValueError(
            "--source-delta and --expected-source-delta-sha256 must be supplied together"
        )
    items = select_items(read_jsonl(args.manifest), args.limit)
    if not items:
        raise ValueError("No parity items fit the fixed 30-second Core ML window")
    args.output.mkdir(parents=True, exist_ok=True)
    reports: list[dict[str, object]] = []
    for index, item in enumerate(items, 1):
        item_id = str(item["id"])
        item_root = args.output / item_id
        source = item_root / "source"
        coreml = item_root / "coreml"
        report_path = item_root / "report.json"
        audio_path = item.get("audioPath") or item.get("audio_path")
        if not audio_path:
            raise ValueError(f"Parity item has no audio path: {item_id}")
        duration = float(
            item.get("audioDurationSeconds") or item.get("duration") or 0
        )
        audio = resolve_audio_path(args.audio_root, str(audio_path))
        item_root.mkdir(parents=True, exist_ok=True)
        if not (source / "snapshot.json").exists():
            run(
                [
                    sys.executable,
                    "Tools/parity/export_parakeet_reference.py",
                    "--model",
                    args.source_model,
                    "--revision",
                    args.revision,
                    *(
                        ["--cache-dir", str(args.source_cache_dir)]
                        if args.source_cache_dir
                        else []
                    ),
                    *(
                        [
                            "--delta",
                            str(args.source_delta),
                            "--expected-delta-sha256",
                            str(args.expected_source_delta_sha256),
                        ]
                        if args.source_delta
                        else []
                    ),
                    "--audio",
                    str(audio),
                    "--output",
                    str(source),
                ]
            )
        if not (coreml / "snapshot.json").exists():
            coreml_command = [
                str(args.coreml_cli),
                "--model-root",
                str(args.coreml_model_root),
                "--compute-units",
                args.compute_units,
                "--output",
                str(coreml),
            ]
            if args.source_compatible_features:
                coreml_command.append("--source-compatible-features")
            coreml_command.append(str(audio))
            run(
                coreml_command
            )
        run(
            [
                sys.executable,
                "Tools/parity/compare_parakeet_snapshots.py",
                "--source",
                str(source),
                "--coreml",
                str(coreml),
                "--output",
                str(report_path),
                "--quiet",
            ],
            allow_comparison_failure=True,
        )
        report = json.loads(report_path.read_text(encoding="utf-8"))
        reports.append(
            {
                "id": item_id,
                "audioDurationSeconds": duration,
                "transcriptExact": report["transcriptExact"],
                "tokenEditDistance": report["tokenEditDistance"],
                "tokenNormalizedEditDistance": report["tokenNormalizedEditDistance"],
                "sourceToCoreMLWordErrorRate": report[
                    "sourceToCoreMLWordErrorRate"
                ],
                "attentionMaskExact": report["attentionMaskExact"],
                "encoderMaskExact": report["encoderMaskExact"],
                "coreMLEncoderNonFiniteCount": report["encoderHidden"].get(
                    "coreMLNonFiniteCount", 0
                ),
            }
        )
        print(
            f"[{index}/{len(items)}] {item_id} "
            f"exact={report['transcriptExact']}",
            flush=True,
        )

    aggregate = {
        "schemaVersion": 1,
        "revision": args.revision,
        "computeUnits": args.compute_units,
        "sourceCompatibleFeatures": args.source_compatible_features,
        "sourceDeltaSHA256": args.expected_source_delta_sha256,
        "itemCount": len(reports),
        "transcriptExactCount": sum(row["transcriptExact"] for row in reports),
        "meanTokenNormalizedEditDistance": sum(
            float(row["tokenNormalizedEditDistance"]) for row in reports
        )
        / len(reports),
        "meanSourceToCoreMLWordErrorRate": sum(
            float(row["sourceToCoreMLWordErrorRate"]) for row in reports
        )
        / len(reports),
        "nonFiniteItemCount": sum(
            int(row["coreMLEncoderNonFiniteCount"]) > 0 for row in reports
        ),
        "items": reports,
    }
    (args.output / "suite-report.json").write_text(
        json.dumps(aggregate, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(args.output / "suite-report.json")


if __name__ == "__main__":
    main()
