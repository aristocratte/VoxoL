#!/bin/sh
set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(dirname -- "$script_directory")
manifest="$repository_root/Tests/Performance/Fixtures/owner-pipeline-gate-v1.json"
scorer="$repository_root/Tools/training/score_owner_pipeline_trace.py"
temporary_root=$(mktemp -d -t voxol-owner-pipeline.XXXXXX)
trace_path="$temporary_root/traces.json"
report_path="$temporary_root/report.json"

cleanup() {
    /bin/rm -rf "$temporary_root"
}
trap cleanup EXIT HUP INT TERM

pbpaste >"$trace_path"
python3 "$scorer" \
    --manifest "$manifest" \
    --traces "$trace_path" \
    --output "$report_path" \
    >/dev/null

jq '{
    itemCount,
    rawASR,
    finalText,
    textProcessingImpact,
    criticalSpans,
    byGroup: (
        .byGroup
        | with_entries(
            .value = {
                itemCount: .value.itemCount,
                rawASR: .value.rawASR,
                finalText: .value.finalText
            }
        )
    ),
    failures: [
        .items[]
        | select(
            .rawWER > 0
            or .finalWER > 0
            or any(.criticalSpans[]; .attribution != "preserved")
        )
        | {
            id,
            group,
            rawTranscript,
            finalText,
            rawWER,
            finalWER,
            textProcessingImpact,
            criticalSpans: [
                .criticalSpans[]
                | select(.attribution != "preserved")
            ]
        }
    ]
}' "$report_path"
