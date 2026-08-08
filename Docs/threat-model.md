# VoxoL threat model

## Scope and trust boundaries

VoxoL captures microphone audio, reads a bounded Accessibility context, runs two local model
runtimes and inserts text into the focused control. Runtime model downloads are the only intended
network operation. Dictation, cleanup, validation, personalization and insertion stay on the Mac.

## Protected assets

- microphone samples and transcripts;
- nearby text, selected text and the focused control;
- dictionary entries, snippets, profiles and approved correction pairs;
- clipboard contents;
- verified Parakeet and Qwen runtime artifacts.

## Threats and controls

| Threat | Primary controls | Verification |
| --- | --- | --- |
| Context or transcript leaves the Mac | No cloud inference dependency; model installation is separate from dictation; content-free logs and diagnostics | Repository policy check and diagnostic export inspection |
| Password or secure control is captured | Accessibility role/subrole deny-list; secure snapshots discard all text | `ContextKitTests` |
| Prompt injection makes Qwen answer or add content | Immutable non-thinking prompt, bounded generation, protected placeholders, vocabulary-subset validator and deterministic fallback | `FidelityValidatorTests` and Qwen smoke test |
| Numbers, paths, URLs, flags or names change | Deterministic placeholders must occur exactly once in output | `TextProcessingTests` and `FidelityValidatorTests` |
| Clipboard contents are lost | Ownership token and change-count check before restoration; manual recovery is blocked for secure-field failures | `InsertionPolicyTests` |
| A runtime artifact is replaced | Exact repository revision, per-file size and SHA-256 verification before atomic activation | `RuntimeModelManifestTests` |
| Local personalization is read from disk | SQLite content columns are AES-GCM encrypted; the 256-bit key is stored in Keychain; database permissions are `0600` | `PersonalizationTests` |
| Sensitive content enters logs or support exports | Logs contain durations, counts, routes and error classes only; exported diagnostics omit audio, transcript and context | Manual schema review and localization check |
| Partial ASR races final ASR | One actor-isolated Parakeet pipeline; partial text is display-only and final decode is authoritative | `StableTranscriptTests` and launch smoke |
| App exits during a model download | Byte-range resume metadata and temporary artifacts survive relaunch; verified files are atomically promoted | `ModelManagerKitTests` and installer UI |
| Compromised release | Hardened Runtime, Developer ID signing, notarization and stapling in the release procedure | `Scripts/notarize-release.sh` with release credentials |

## Residual risk and release gates

Accessibility permission is intentionally broad at the operating-system level, so VoxoL minimizes
what it reads and never persists session context. Core ML and MLX are native code in the process;
malformed but checksum-valid artifacts remain a supply-chain risk, so release manifests must be
reviewed and pinned. Notarization, a representative audio corpus, energy profiling and the final
p95 release-to-paste gate require release credentials and measurements on the reference Mac before
shipping.
