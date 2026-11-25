# VoxoL threat model

## Scope and trust boundaries

VoxoL captures microphone audio, reads a bounded Accessibility context, runs two local model
runtimes and inserts text into the focused control. The only network operations are the update
check (GitHub release list, every six hours, switchable off), the update download the user accepts,
and the model downloads from Hugging Face the user starts (the two runtime models and the meeting
speaker model). Dictation, cleanup, validation, personalization and insertion stay on the Mac.

## Protected assets

- microphone samples and transcripts;
- nearby text, selected text and the focused control;
- dictionary entries, snippets, profiles and approved correction pairs;
- clipboard contents;
- verified Parakeet, Qwen and speaker-model artifacts;
- the installed application, which the updater can replace;
- local history, metrics, meeting archives and optional benchmark audio.

## Threats and controls

| Threat | Primary controls | Verification |
| --- | --- | --- |
| Context or transcript leaves the Mac | No cloud inference dependency; no telemetry or account; the few network requests carry no dictated content; the metrics log holds no words | `rg "URLSession\|URLRequest" App Packages` and diagnostic export inspection |
| Password or secure control is captured | Accessibility role/subrole deny-list; secure snapshots discard all text | `ContextKitTests` |
| Prompt injection makes Qwen answer or add content | Immutable non-thinking prompt, bounded generation, protected placeholders, vocabulary-subset validator and deterministic fallback | `FidelityValidatorTests` and Qwen smoke test |
| Numbers, paths, URLs, flags or names change | Deterministic placeholders must occur exactly once in output | `TextProcessingTests` and `FidelityValidatorTests` |
| Clipboard contents are lost | Ownership token and change-count check before restoration; manual recovery is blocked for secure-field failures | `InsertionPolicyTests` |
| A runtime artifact is replaced | Exact repository revision, per-file size and SHA-256 verification before atomic activation | `RuntimeModelManifestTests` |
| Local personalization is read from disk | SQLite content columns are AES-GCM encrypted; the key is stored in Keychain; database permissions are `0600` | `PersonalizationTests` |
| Dictation history is read from disk | Not mitigated by VoxoL: `transcripts.json`, the meeting archives and benchmark audio are not encrypted, so protection relies on macOS (for example FileVault). Private mode, per-dictation deletion and full erase limit what stays | Manual review |
| Diagnostics hold dictated words | `repair-shadow.jsonl` keeps recognized low-confidence words and dictionary candidates, capped at 5 MB and suspended in private mode | Manual review |
| Sensitive content enters logs or support exports | Logs contain durations, counts, routes and error classes only; exported diagnostics omit audio, transcript and context | Manual schema review and localization check |
| Partial ASR races final ASR | One actor-isolated Parakeet pipeline; partial text is display-only and final decode is authoritative | `StableTranscriptTests` and launch smoke |
| App exits during a model download | Byte-range resume metadata and temporary artifacts survive relaunch; verified files are atomically promoted | `ModelManagerKitTests` and installer UI |
| Compromised release | Builds are signed with Apple Development and not notarized today. The updater checks bundle identifier, signing team, `codesign --verify --deep` and version, but not `spctl` or a published SHA-256. Developer ID signing, notarization and stapling are planned in `release.yml` and have not completed | `UpdateCheckTests` for the version rule |

## Residual risk and release gates

Accessibility permission is intentionally broad at the operating-system level, so VoxoL minimizes
what it reads and does not write session context to history, metrics or diagnostics. Core ML and MLX are native code in the process;
malformed but checksum-valid artifacts remain a supply-chain risk, so release manifests must be
reviewed and pinned. Notarization (no Developer ID certificate yet), a representative audio corpus, energy profiling and
the final p95 release-to-paste gate remain open before a public release.
