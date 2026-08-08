# ASR runtime benchmark decision — 2026-08-03

## Decision

Promote `nemo-direct-waveform-int8` as the VoxoL ASR training and product-test baseline. It improves all three frozen external benchmarks against the currently installed legacy-front-end runtime while using the same fine-tune delta (`5207971b31f19306ddb4fdcaf6bac8575cca3badb67f0c684fe80318a4cb685d`).

Do not overwrite the installed model under its existing provider revision. The two Core ML encoder artifacts have different weight hashes, so the direct runtime must keep a distinct manifest/revision until its distribution hashes are published.

## Frozen results

| Benchmark | Installed WER | Direct-NeMo WER | Relative WER change | Installed p95 | Direct-NeMo p95 |
| --- | ---: | ---: | ---: | ---: | ---: |
| FLEURS FR+EN | 5.3868% | 5.3234% | -1.18% | 162.4 ms | 135.8 ms |
| LibriSpeech test-clean + test-other | 3.0890% | 3.0261% | -2.04% | 135.4 ms | 135.3 ms |
| MediaSpeech FR | 31.3095% | 29.9383% | -4.38% | 161.5 ms | 145.6 ms |

The comparison gate passed on 9,380 frozen utterances. These corpora remain evaluation-only and must never enter fine-tuning data.

## Provenance

- Installed encoder SHA-256: `beba2b44c18650a6ef0f1a99dcada7e3a1c797873979a1ae58fc873a7ff7a284`
- Direct-NeMo encoder SHA-256: `39d48ecb61b59400627e3df32fdb538be1d7d779111a4ff7eff7a3ec5e738655`
- Comparison: `/Volumes/0_Oueillez/VoxoL-Benchmarks-v2/comparisons/installed-vs-direct-nemo-20260803.json`
- Frozen benchmark root: `/Volumes/0_Oueillez/VoxoL-Benchmarks-v2/benchmarks`

## Next gate

Fine-tune from the direct-NeMo source/runtime path only after the new speaker/source-disjoint Wispr-teacher corpus is complete. Promotion still requires improvement on these untouched external benchmarks plus the VoxoL product-shaped holdout.
