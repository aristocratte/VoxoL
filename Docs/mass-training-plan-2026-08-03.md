# VoxoL mass-training plan — 2026-08-03

## Objective

Build a source/speaker-disjoint FR/EN Wispr-teacher corpus large enough for a real Parakeet adaptation, while keeping every public benchmark evaluation-only. Long-form sources are segmented at pauses around 18 seconds so Qwen sees complete utterances rather than artificial 30-second boundaries.

## Data campaign

- Primary frozen source list: 60.35 hours, balanced at about 30 hours per language.
- Reserve source list: 14.71 hours (6.70 FR, 8.01 EN) to replace unavailable links and increase diversity.
- Historical Wispr corpus: 23.92 hours, retained with its existing frozen recording/speaker splits.
- Public tests: FLEURS FR/EN, MediaSpeech FR, LibriSpeech test-clean/test-other and AMI meeting evaluation. None can enter training or checkpoint selection beyond the explicitly separate validation gates.

## ASR recipe

The combined package streams audio from both corpus roots without staging copies. Old split assignments remain frozen; new recordings are assigned by connected speaker/source groups with zero overlap.

RunPod uses the direct-NeMo Parakeet source path, trains the top four encoder layers with decoder/joint/BatchNorm frozen, targets 25% FLEURS replay, and derives the budget from one effective pass over the mixed manifest. The budget is bounded to 400–1,600 optimizer steps with roughly ten checkpoints, so the run is large enough to use the corpus but still selected before overfitting.

Every result remains a challenger until it passes the Wispr holdout, public source gates, Core ML conversion parity and the frozen Mac latency suite. Uploads are byte-resumable and SHA-256 verified before GPU work starts.

## Qwen recipe

Keep installed v6 until the new utterance-complete corpus yields at least 500 internal post-cleanup corrections, including 150 source-disjoint validation/test cases balanced across FR/EN. Build inputs from the exact direct-NeMo raw text; Wispr edited is a silver target, while the adjudicated GPT Pro corpus supplies higher-quality gold examples. Boundary-only casing or punctuation changes are excluded.

The next local LoRA is promoted only if clean WER improves by at least 5% relative to v6, protected spans remain at 100% after runtime fallback, unexpected words do not increase and p95 stays inside the current envelope.
