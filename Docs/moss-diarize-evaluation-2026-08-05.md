# MOSS-Transcribe-Diarize for the meeting mode

`SignalMeetingsView` has been a preview with nothing behind it. Meetings need
two things dictation does not: separating who spoke, and tolerating minutes of
audio rather than seconds. `OpenMOSS-Team/MOSS-Transcribe-Diarize` does both in
one pass under Apache-2.0.

Its card claims 50+ languages while its metadata declares only English and
Chinese, so its French was an open question — and French is the language this
product cannot be mediocre in. It was measured rather than assumed.

## Result

100 clips, MediaSpeech FR, the same human reference and the same Swift scorer as
every other system.

| | Word error | Seconds per clip |
| --- | ---: | ---: |
| **MOSS-Transcribe-Diarize 0.9B** | **15.641%** | 13.28 |
| VoxoL | 18.780% | 0.145 |
| Wispr Flow | 19.776% | ~3.3 (network) |

**MOSS is 3.1 points better than VoxoL in French and 4.1 better than Wispr**, on
a corpus whose own references are known to be defective. Its French is not a
marketing claim.

It is also **92× slower than VoxoL**. On MPS with PyTorch it takes about as long
as the audio itself — fine for a recording, unusable for the moment between
releasing a key and seeing text appear.

## What this settles

**Two models, two jobs.** Parakeet keeps live dictation, where 145 ms is the
whole product. MOSS takes meetings, where the recording is already over and
speaker labels matter more than latency. Nothing about the dictation path
changes.

Wispr's meeting mode goes through their servers. A local one that is also more
accurate in French is a genuine differentiator rather than a catch-up feature.

## Caveats

**Diarization over-splits.** On single-speaker clips it reported 1.28 speakers on
average, so it invents a second voice roughly a quarter of the time. Short
clips are the hard case for diarization and a real meeting gives it far more to
work with, but the merge logic needs checking before any transcript is shown
with speaker names on it.

**The MLX path is a fork.** The official repository ships only a PyTorch runtime;
the MLX conversions and their CLI come from third parties. Running MOSS at
acceptable speed on Apple Silicon means either adopting a fork, converting the
weights, or accepting PyTorch on MPS. For batch meeting processing PyTorch is
probably enough.

**Measured on 100 clips**, chosen by a deterministic stride across the corpus
rather than the first hundred. Enough to rank three systems; not enough to
publish a precise figure.

## A larger consequence

MOSS is Apache-2.0, runs locally, and is **3.1 points better than Wispr in
French**. The entire teacher corpus was distilled from Wispr's API — a legally
awkward dependency that caps VoxoL at the teacher's quality.

A better teacher now exists that carries neither problem. Re-labelling the
French corpus with MOSS would give training targets above Wispr's ceiling, from
a source that permits it. That is worth measuring before the next fine-tune.
