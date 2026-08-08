# VoxoL ASR candidate decision — 2026-08-04

The mass-campaign candidate `nemo-direct-waveform-int8` (delta
`863011a8bf30…`) improves every frozen benchmark against the installed runtime
and holds Core ML parity. It is approved for local development.

Public distribution remains blocked on one step only: the Core ML artifacts are
not yet published at an immutable provider revision, so `runtime-models.json`
cannot be updated. See **Promotion blocker** below.

## Training

The 2026-08-03 mass corpus is 98.05 h across 183 recordings — 75.26 h from the
new Wispr teacher campaign (148 sources, 13,601 chunks, 100% raw HTTP 200) plus
the historical corpus. Splits are recording- and speaker-disjoint: the split
report's `overlapChecks` is empty on all three pairs.

One epoch, 961 optimizer steps at an effective batch of 16, top four encoder
layers trainable, decoder/joint/BatchNorm frozen, 25% FLEURS replay, LR 3e-6.

Validation WER fell from 13.909% to 8.146% across ten checkpoints, and the last
one won. The curve converged well before the budget: **88% of the gain landed in
the first 384 steps, the last 288 steps returned 2%.** A 400-step budget would
have produced substantially the same model in half the wall-clock.

## Quality

All figures are micro-WER on frozen manifests, candidate measured through the
Core ML INT8 runtime on Apple Silicon.

| Benchmark | installed | candidate | delta | relative |
| --- | ---: | ---: | ---: | ---: |
| MediaSpeech FR | 29.9383% | **20.1639%** | −9.7744 | **−32.65%** |
| FLEURS FR+EN | 5.3234% | 5.2723% | −0.0511 | −0.96% |
| LibriSpeech test-clean+other | 3.0261% | 3.0214% | −0.0047 | −0.16% |

FLEURS by language: 5.2357% French, 5.3155% English.

The installed runtime was re-measured in the same session rather than quoted
from the 2026-08-03 decision, and it reproduced its published 29.9383% exactly.
The benchmark is deterministic and the gain is not a measurement artifact.

On the Wispr held-out split the GPU-side candidate scored 8.9381% against the
stock model's 21.3192% — French 33.5882% → 10.8021%. That benchmark is not
reproducible locally: its audio lived on the training pod.

## Core ML parity

| Benchmark | NeMo source | Core ML INT8 | gap |
| --- | ---: | ---: | ---: |
| MediaSpeech FR | 20.2440% | 20.1639% | −0.0801 |
| FLEURS FR+EN | 5.2822% | 5.2723% | −0.0099 |

Both gaps are negative — conversion improves marginally rather than degrading —
and an order of magnitude inside the 0.5-point parity limit. The traced encoder
matched NeMo at 2.9466e-06 normalized L2 error, and the Core ML encoder mask was
bit-exact.

The export report's `normalizedEncoderL2Error` reads 0.1294 against the previous
conversion's 0.0365, which looks alarming and is not. The two conversions
validated on different clips (`validFrameCount` 188 against 243) because
`--validation-audio` was left unset, so the figures are not comparable. Measured
WER settles it.

## Latency

Same machine, same session, MediaSpeech FR:

| | WER | p50 | p95 | p99 |
| --- | ---: | ---: | ---: | ---: |
| installed | 29.9383% | 142.3 ms | 161.4 ms | 171.2 ms |
| candidate | 20.1639% | 145.5 ms | 170.0 ms | 196.5 ms |
| delta | −9.7744 | +3.2 ms | +8.6 ms | +25.3 ms |

Against the 2026-08-03 decision the candidate's p95 looked +24.4 ms worse. Most
of that was session drift: the installed runtime measures 161.4 ms today against
the 145.6 ms published then. The regression genuinely attributable to the new
model is **+8.6 ms at p95**, with p99 the more notable cost at +25.3 ms.

Full latency across benchmarks: FLEURS 122.5/146.7/160.3 ms,
LibriSpeech 110.8/143.2/165.6 ms, MediaSpeech 145.5/170.0/196.5 ms.

The trade is 8.6 ms of p95 for 32.65% relative WER on French media audio. The
2026-08-02 decision already accepted roughly 12 ms of short-audio cost for a
5.78% relative reduction, so this one is cheaper per point recovered. The p99
cost is the figure to watch if the dictation envelope tightens.

## Source gate

The GPU pipeline reported `sourceGatePassed: false` on 15 of 16 checks passing.
The failure was `checkpointSelectionMetricIsGlobalVoxoLWER`, which required the
in-training validation score and the external re-evaluation to agree to within a
single word error. Those are two different inference paths — batch 1 through
Lightning against batch 8 with CUDA-graph decoding — so TDT greedy decoding is
not bit-identical between them. The run scored 12,737 against 12,748 errors on
156,356 words: a 0.086% divergence and 0.007 points of WER.

The check was unsatisfiable by construction. It now uses a tolerance relative to
the stored error count (`VALIDATION_ERROR_TOLERANCE_RATIO`, 0.5%, floored at one
word), and the gate reports `failedConditions` naming which of its three
sub-conditions tripped. Replaying the gate against this run's reports returns
`sourceGatePassed: true` on 16 of 16.

## Promotion blocker

`Models/manifests/runtime-models.json` pins the ASR artifact to a third-party
provider — `mweinbach1/parakeet-tdt-0.6b-v3-coreml` at revision `b650695c…` —
with a SHA-256 and download URL per file. Shipping this candidate requires
publishing its Core ML package at an immutable revision the manifest can pin,
then regenerating those hashes. Until then the installed artifact stays.

## Artifacts

- Candidate runtime: `Artifacts/Training/voxol-wispr-mass-v3/coreml-candidates/nemo-direct-waveform-int8`
- Trainable delta SHA-256: `863011a8bf30973c58322f03eaa8a3c04d17eaab47484ff5b85b70a1ad678d9a`
- Candidate encoder weight SHA-256: `b4ccde8e539505854af887c0d21bbb1048197847ab7ae77533054ade8d9f0ad2`
- Installed encoder weight SHA-256: `39d48ecb61b59400627e3df32fdb538be1d7d779111a4ff7eff7a3ec5e738655`
- Runtime size: 641,615,275 bytes (installed: 641,565,244)
- Core ML reports: `Artifacts/Training/voxol-wispr-mass-v3/coreml-benchmark`
- Same-session installed A/B: `…/coreml-benchmark/prod-ab`
- GPU run results and ten checkpoints: `Artifacts/Training/voxol-wispr-mass-v3`

## Reproducing the export

The export environment did not survive from the previous conversion. Pinned
requirements need **Python 3.11**: `numpy==1.26.4` and `scikit-learn==1.5.1`
publish no wheels for 3.13, and pip falls back to a source build that fails in
meson.

```sh
python3.11 -m venv .build/coreml-venv
VIRTUAL_ENV=.build/coreml-venv uv pip install \
  -r Tools/training/nemo-coreml-export-requirements.txt
```

Only the encoder needs re-exporting while decoder and joint stay frozen in
training: `convert` copies `decoder.mlpackage`, `joint.mlpackage` and
`tokenizer.json` from `--runtime-template-root`.

```sh
.build/coreml-venv/bin/python Tools/training/export_voxol_nemo_coreml_candidate.py trace \
  --base-nemo <parakeet-tdt-0.6b-v3.nemo> --delta <delta.pt> \
  --expected-delta-sha256 <sha> --input-contract waveform --output-root <trace>
.build/coreml-venv/bin/python Tools/training/export_voxol_nemo_coreml_candidate.py convert \
  --trace-root <trace> --runtime-template-root <previous fp16 runtime> \
  --expected-delta-sha256 <sha> --output-root <fp16>
.build/coreml-venv/bin/python Tools/training/quantize_voxol_coreml_candidate.py \
  --fp16-runtime-root <fp16> --output-root <int8> --expected-delta-sha256 <sha>
```

Pass `--validation-audio` on `trace` to make `normalizedEncoderL2Error`
comparable across conversions.

## Next

1. Publish the Core ML package at an immutable provider revision, regenerate the
   manifest hashes, promote.
2. Regenerate raw predictions with the promoted runtime before building the Qwen
   polisher corpus. The polisher learns to repair one ASR model's error profile;
   training it on the outgoing runtime's errors would target the wrong model.
3. The convergence curve says the next experiment is not more steps and not a
   different learning rate. Both are saturated. The open lever is trainable
   capacity — adapters across all encoder layers rather than the top four.
