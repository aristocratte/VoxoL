# VoxoL ASR candidate decision — 2026-08-02

The Wispr replay v5 direct-NeMo INT8 Core ML candidate is approved for local
development. Source/Core ML parity now passes. Public distribution remains
blocked only until the exact runtime is published at an immutable provider
revision and its hashes replace the legacy conversion manifest.

## Quality result

| Benchmark | NeMo source | Previous Core ML with decoder fix | Selected Core ML | Decision |
| --- | ---: | ---: | ---: | --- |
| Wispr held-out, 559 clips | 6.6869% | 6.6169% | 6.2347% | pass |
| Wispr held-out French | 8.8596% | 8.4151% | 7.8694% | pass |
| Wispr held-out English | 4.2410% | 4.5927% | 4.3946% | pass |
| FLEURS French, 676 clips | 5.4173% | — | 5.3880% | pass |
| MediaSpeech French, 2,498 clips | 30.7065% | — | 29.9383% | pass |

The selected candidate retains one empty private output, equal to NeMo and the
previous runtime. Its absolute private WER gap to NeMo is -0.4522 point, inside
the 0.5-point parity limit. English trails NeMo by only 0.1536 point while
French improves by 0.9903 point.

## Correctness fixes

Three implementation defects, rather than insufficient training data, caused
most of the prior gap:

1. The Swift TDT loop committed candidate LSTM hidden/cell state after blank
   decisions. NeMo commits it only after a lexical emission and reuses the
   prediction across blanks.
2. Applying a NeMo-trained encoder delta behind the Transformers feature
   front-end lost learned French behaviour. The selected encoder fuses NeMo's
   waveform preprocessor, encoder and projection in one Core ML graph.
3. A 30.000-second WAV exceeded the old graph by one 10 ms hop and was split
   into overlapping windows. VoxoL now trims only that final hop; longer audio
   remains segmented normally. This recovered complete phrases without using
   the slower 376-frame graph.

The Transformers parity exporter now mirrors the same predictor-state policy,
so future diagnostics cannot silently reproduce the old decoder bug.

## Runtime decision

The selected runtime is full per-channel linear INT8 and occupies 641,565,244
bytes before compilation. On the frozen private set it measured 209.31 ms p50,
301.59 ms p95 and 633.97 ms p99. The previous installed Core ML runtime with
the decoder fix measured 245.83/425.37/623.06 ms on the same 559 files.

An alternating 128-file short-audio A/B measured the selected front-end at
143.87 ms pooled p50 versus 131.88 ms for the previous compact graph. The
roughly 12 ms short-audio cost buys a 5.78% relative private WER reduction and
removes catastrophic language drift. On the representative private corpus,
avoiding unnecessary 30-second segmentation makes the selected runtime faster
overall.

The exact FP32 NeMo decoder/joint export is rejected: its logits were nearly
identical but its latency was materially worse, while the optimized heads
changed only 5 of 559 transcripts. The 480,000-sample/376-frame encoder is also
rejected because it slowed ordinary short dictations; the one-hop boundary
policy provides the same recovery with the 479,840-sample runtime.

## Evidence

- Selected runtime: `Artifacts/Training/2026-08-01-wispr-replay-v5/coreml-candidates/nemo-direct-waveform-int8`
- Final private report: `Artifacts/Training/2026-08-01-wispr-replay-v5/coreml-benchmark/nemo-direct-waveform-int8-statefix-boundarytrim-wispr-report.json`
- FLEURS report: `Artifacts/Training/2026-08-01-wispr-replay-v5/coreml-benchmark/nemo-direct-waveform-int8-statefix-fleurs-fr-report.json`
- MediaSpeech report: `Artifacts/Training/2026-08-01-wispr-replay-v5/coreml-benchmark/nemo-direct-waveform-int8-statefix-mediaspeech-fr-report.json`
- Source delta SHA-256: `5207971b31f19306ddb4fdcaf6bac8575cca3badb67f0c684fe80318a4cb685d`
- Encoder weight SHA-256: `39d48ecb61b59400627e3df32fdb538be1d7d779111a4ff7eff7a3ec5e738655`

## Local activation

`Scripts/launch-local-asr-candidate.sh` now launches the signed development app
with the selected runtime through `VOXOL_ASR_MODEL_ROOT`. The verified public
installation directory is intentionally left unchanged because its current
manifest still pins the legacy provider files. This keeps rollback immediate
and prevents the UI from claiming that an unpublished artifact passed its
download hashes.
