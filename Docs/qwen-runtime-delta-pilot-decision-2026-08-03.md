# Qwen runtime-delta pilot decision — 2026-08-03

## Decision

Reject the Qwen v7 pilot and keep the installed v6 adapter unchanged. The pilot did not learn any
of the six isolated product deltas and regressed the frozen 64-example gate despite a small gain in
raw protected-token recall.

## Reviewed return

The 475-result archive has SHA-256
`b0f4d7397233785503d772de9c8a94ebd1e26a56cbaefbf914ab494721f16f91`. Validation covered all
475 sealed inputs with no missing, extra, duplicate, corrupt, schema-invalid or seal-invalid item.
The decisions were 378 accepted GPT targets, 69 deterministic baselines, 27 replacement targets and
one unrecoverable exclusion.

The production dataset validator accepted 1,391 of the 1,570 merged source rows. After fixing the
deterministic `,.` terminal-punctuation bug, 415 accepted targets differed nominally from the exact
runtime baseline. Of those, 372 changed only artificial 30-second video boundaries. The resulting
product-shaped signal contains 43 real deltas:

| Split | English | French | Total |
| --- | ---: | ---: | ---: |
| Train | 32 | 5 | 37 |
| Validation | 1 | 1 | 2 |
| Test | 2 | 2 | 4 |

The 372 boundary-only rows were not used as corrections because they would teach Qwen to lowercase
captured utterance starts or omit terminal punctuation. The training source combined the existing
393-example reviewed curriculum with only the 37 real train deltas, for 430 train examples. The six
validation/test deltas remained isolated.

## Pilot recipe

- Base: installed Qwen3.5-0.8B 4-bit runtime.
- Resume point: installed v6 LoRA checkpoint 400.
- LoRA: rank 8, top eight hybrid layers, 0.819 million trainable parameters.
- Run: 120 iterations, learning rate `5e-6`, sequence limit 512.
- Peak MLX memory reported by the trainer: 6.715 GB; no OOM or NaN occurred.
- Candidate adapter SHA-256:
  `2d21253cb99199d10cd64198187814afc35650d44349f5c9fc826ab7ed4b35d1`.

## Frozen-gate result

Both adapters were evaluated on the same frozen, balanced 64-example test subset.

| Metric | Installed v6 | Pilot v7 | Decision |
| --- | ---: | ---: | --- |
| Micro WER, raw output | 4.9866% | 6.9326% | v7 is 39.0% worse relative |
| Micro WER, placeholder fallback | 3.4541% | 5.1326% | v7 is worse |
| Raw protected-token recall | 69.89% | 74.19% | v7 is better |
| Placeholder-fallback recall | 100% | 100% | tie |
| Unexpected-word rate | 2.768% | 4.114% | v7 is worse |
| Latency p50 | 931.8 ms | 975.0 ms | v7 is slower |
| Latency p95 | 1,292.9 ms | 1,363.7 ms | v7 is slower |

On the six newly isolated product deltas, v6 and v7 produced byte-identical outputs. The intermediate
step-100 checkpoint was also worse than v6 on the frozen gate, so there is no promotable checkpoint
from this run.

## Next data gate

The limiting resource is no longer hours of continuous video. It is the number of product-shaped,
non-zero corrections after VoxoL's deterministic cleanup. Before another Qwen fine-tune, collect at
least 500 such corrections, including at least 150 source-disjoint validation/test cases, balanced
across French and English. Segments must end at real push-to-talk or speech boundaries rather than
arbitrary 30-second cuts.

More long-form video is useful only if it is resegmented into complete utterances and yields actual
internal corrections. Boundary-only casing and punctuation variants must remain excluded. The next
fine-tune should be promoted only if it improves clean WER by at least 5% relative to v6, preserves
100% of protected spans after runtime validation, does not increase unexpected words and remains at
or below the existing latency envelope.
