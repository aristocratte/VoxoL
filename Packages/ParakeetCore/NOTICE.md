# ParakeetCore attribution

This module is adapted from `parakeet-coreml-swift`, copyright 2026 Max Weinbach, revision
`75aec2a1c991319657ff4dec5f602c12da6c5012`, licensed under Apache License 2.0.

VoxoL changes the source to use only its separately verified local model installation, expose an
async application runtime, support Swift 6 isolation, cache compiled Core ML artifacts beside the
verified source packages, and integrate transcription metrics and cancellation with VoxoL.
Vocabulary-biased selection materializes sparse offsets while preserving the original winner
selection and leaving model outputs untouched.
Exact session-scoped encoder caching retains at most sixteen entries under a 64 MiB accounting
budget to avoid eviction cascades on three-minute recordings, with opt-in content-free tracing.

The converted Parakeet model weights remain separately downloaded and are licensed under CC BY 4.0.
They are not part of this source module or the VoxoL application bundle.
