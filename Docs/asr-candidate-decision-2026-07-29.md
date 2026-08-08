# VoxoL ASR candidate decision — 2026-07-30

The Wispr-trained INT8 Core ML candidate is installed for local development.
The previous installed model remains available as a recoverable backup. Public
release is still blocked because the INT8 runtime remains 1.45 absolute WER
points behind the NeMo source candidate on the Wispr heldout set and no
immutable public artifact URL exists.

## Measured result

| Benchmark | Previous Core ML | INT8 candidate | Change |
| --- | ---: | ---: | ---: |
| Wispr heldout, 269 clips | 19.25% WER | 8.25% WER | -57.2% relative |
| FLEURS French, 676 clips | 6.82% WER | 6.44% WER | -5.7% relative |
| MediaSpeech French, 2,498 clips | 40.04% WER | 33.00% WER | -17.6% relative |

On the Wispr set, median inference falls from 186.8 ms to 163.9 ms, p95 falls
from 246.2 ms to 220.3 ms, and empty outputs fall from two to one. The
candidate improves French from 34.06% to 12.10% WER. English moves from 4.13%
to 4.31%, a 0.18-point absolute regression that must remain visible in later
gates.

The INT8 runtime contains 640,793,846 bytes before Core ML compilation. FP16
is only 0.15 WER point better on the Wispr set, but is nearly twice as large
and slower at p50. INT4 and the earlier mixed-precision export stalled during
ANE cold loading and remain rejected.

## Source, Core ML and Swift parity

The FP16 graph matches the source transcript on all six duration-stratified
parity clips, with zero mean source-to-Core-ML WER. INT8 matches three of six
and has 0.72% mean source-to-Core-ML WER. This isolates the remaining small
parity gap to quantization/runtime numerics rather than the Swift greedy
decoder.

A second hybrid preserved the four fine-tuned encoder layers and output
projector in FP16 while quantizing the rest. It produced the same 0.72% mean
parity WER as full INT8 with slightly worse token edit distance, so it is
rejected instead of being benchmarked or shipped.

The tokenizer now collapses only repeated sentence-punctuation pieces. It
preserves repeated lexical pieces, repeated words and command hyphens. A
global CTC-style duplicate collapse was tested and rejected because TDT can
legitimately emit identical consecutive lexical tokens.

## Local activation

The candidate is active under:

`~/Library/Application Support/VoxoL/Models/asr/7c35754d166cca382ad1e53e68b01e7c575f3a1d`

The previous model and its compiled cache are preserved under:

`~/Library/Application Support/VoxoL/Models/asr/.backup-base-20260730T140845Z`

The staged files were hashed before and after the same-volume atomic swap. A
five-second smoke transcription loaded the active runtime and reproduced the
previous candidate output exactly.

## Release gate

Do not publish this model from the local installation. Release requires an
immutable artifact, exact manifest checksums, a repeated source/Core ML parity
suite larger than six clips, and the normal public benchmark gates. The
development promotion is justified by the large measured product gain; it
does not waive the release requirements.
