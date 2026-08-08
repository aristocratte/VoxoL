# VoxoL optimization handoff — 2026-07-30

VoxoL now runs the fine-tuned INT8 Parakeet candidate and the guarded Qwen v6
adapter locally. The changes address separate failure classes: Parakeet
improves word recognition, while deterministic cleanup plus selectively routed
Qwen improves presentation without allowing factual drift.

## Promoted locally

- Parakeet INT8 candidate
  `3c7f959497a90592c7adbe137c61924ae4f39fec443a3abe12f12de6408b79b6`.
- Qwen3.5-0.8B v6 LoRA checkpoint 400,
  `55f2c10bb9870e02d6e56526031803cbdc0cec9c26217ad38994d9e1d07dd630`.
- Selective polisher routing, bounded prompt/output budgets, prefix reuse and
  strict safe fallback.
- Sentence-punctuation duplicate cleanup without lexical-token collapse.

## Rejected

- Running Qwen on every dictation: no aggregate gain after validation on the
  192-example test and unnecessary latency.
- Global duplicate-token grouping: it removes legitimate repeated lexical
  pieces and degrades ASR output.
- FP16 Parakeet for the lightweight product path: negligible quality gain for
  substantially more size and slower median inference.
- Hybrid top-four-layer FP16 Parakeet: no parity gain over INT8.
- INT4 and the older mixed export: unacceptable Core ML cold-load stalls.

## Verification

- 123 Swift tests pass.
- 97 Python tests pass.
- `Scripts/verify.sh` passes repository policy, generated-artifact checks,
  strict formatting, benchmark smoke, Debug build, localization, signing and
  launch smoke.
- The macOS Release build succeeds with four compile jobs.
- The active ASR model passes a real Core ML smoke inference and matches the
  benchmark candidate output.

## Remaining work

The current result is a development promotion. Before distribution, publish
immutable Parakeet and Qwen artifacts, update their signed checksums in the
runtime manifest, repeat the ASR parity suite on at least 30 clips and run a
fresh independent FR/EN dictation benchmark. New teacher data should expand
speaker, microphone, accent, code-switch and real dictation coverage. It
should not be used to retune thresholds on the frozen heldout sets.

Manual or GPT-assisted correction is useful only for a provenance-tracked
training review queue. It must never alter validation/test labels after model
outputs have been inspected, because that would make later quality numbers
unreliable.
