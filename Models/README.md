# Model artifacts

This directory contains metadata only. Model weights, converted artifacts and compiled model
bundles are excluded from Git.

`manifests/runtime-models.json` pins the exact upstream and conversion-provider Git revisions.
Every downloadable artifact records each output file's byte size, SHA-256 and immutable URL. The
Parakeet artifact additionally passes a local Core ML load and transcription smoke test.

Updating an upstream revision is a reviewed dependency change: verify the model card and license,
record the new immutable commit, rerun conversion, regenerate every checksum and execute all
golden tests. Never replace a revision with `main` in a release manifest.
