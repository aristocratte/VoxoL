# Changelog

All notable changes will be documented here.

## Unreleased

### Added

- Phase 0 native macOS bootstrap.
- Runtime-model manifest contract for the two allowed local models.
- Versioned benchmark-result contract and manifest-validation benchmark CLI.
- Initial ADR set, repository policy checks and CI workflow.
- Warm monochrome VoxoL mark and native macOS app icon.
- Real microphone, Accessibility and Input Monitoring setup flow.
- Checksum-verified model installer states with byte-level progress and cancellation.
- Local transcript metrics, searchable history, revision undo and opt-in audio export.
- Compact morphing voice capsule with success, fallback and error states.
- End-to-end local Parakeet TDT transcription with vDSP feature extraction, Core ML acceleration,
  optimized Swift decoding, model preloading and direct insertion into the focused application.
- Runtime ASR smoke test and regression coverage for feature extraction and tokenizer decoding.
- Captured Accessibility insertion targets, safe manual-paste recovery and a content-free last-run
  diagnostic showing microphone level, endpointing, ASR latency and delivery outcome.
