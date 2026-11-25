# Privacy

VoxoL runs speech recognition and text cleanup on the Mac. It has no account, no analytics SDK and
no telemetry. Audio, transcripts and application context are never sent to a VoxoL server or to any
cloud inference service.

## Network requests

VoxoL makes these requests and no others:

- Update check: reads the public release list of `aristocratte/VoxoL` on GitHub at launch, then
  every six hours. The switch "Automatic update check" in Settings, About, turns it off. The
  request carries no dictated content.
- Update download: fetches the disk image attached to the GitHub release, only when you accept an
  update.
- Model download: fetches the two runtime models from Hugging Face when you install them, from
  `arhesstide/voxol-parakeet-tdt-0.6b-v3-coreml` (speech recognition) and
  `mlx-community/Qwen3.5-0.8B-4bit` (text cleanup). Files are checked by size and SHA-256.
- Meeting speaker model: fetches `FluidInference/nemotron-3-diarization-coreml` from Hugging Face
  when you install it from the Meetings screen.
- Report a problem: opens your browser on a prefilled GitHub issue. You submit it yourself. It
  holds versions, hardware model and timings, never your text.

## What is stored on this Mac

All of it lives under `~/Library/Application Support/VoxoL/` and is removed with that folder.

- Dictation history, `transcripts.json`: text, time, destination app and duration of each
  dictation, as readable JSON. It is on by default (`Local history`). Private mode stops new
  entries without changing the setting. You can delete one dictation or erase everything
  ("Erase history", Settings). VoxoL does not encrypt this file; protection against other people
  reading the disk depends on macOS settings such as FileVault.
- Metrics, `Metrics/dictations.jsonl`: one line per dictation with id, time, word count, mode,
  language, destination app identifier, route, timings, polisher outcome and, after insertion,
  an edit-distance count. No words. Private mode suspends it.
- Diagnostics, `Diagnostics/repair-shadow.jsonl`: for dictations with low-confidence words, the
  recognized word and the dictionary term it resembles, with scores. This does contain
  dictated words. It stops growing at 5 MB. Private mode suspends it.
- Dictionary and learned corrections, `personalization.sqlite3`: content columns are encrypted
  with AES-GCM. The key is a Keychain item on this Mac, and the file is readable by your user only.
  For about a minute after each insertion, VoxoL re-reads the destination field to learn the
  corrections you make there ("Correction learning" turns this off for the dictionary; the
  metrics edit count still runs).
- Audio: not kept, unless you turn on "Personal benchmark capture". It then saves each
  dictation's audio, raw text and final text in `PersonalBenchmark/`, up to 500 MB. Private mode
  suspends it.
- Meetings: transcripts and reports are in `Meetings/meetings.json` and `reports.json`, saved only
  while history is on and private mode is off. A recording is written to the file you choose in
  the save dialog.

## Application context

When "Application context" is on (default), VoxoL reads from the focused app, through Accessibility,
its name, window title, document URL, selected text (up to 1,000 characters) and up to 500
characters before and 300 after the cursor (the latter two can be switched off with "Nearby
text"). Secure fields give no text. The context serves the current dictation and is not written
to history, metrics or diagnostics; only the app name and identifier are stored.

Changes that touch audio, context, storage or networking require a privacy test and an
architecture decision. Secrets and user content are never committed to this repository.
