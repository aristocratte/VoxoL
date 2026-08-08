# Multilingual public benchmarks

How VoxoL's published accuracy numbers are produced, and how to reproduce them.

The results themselves live in `multilingual-benchmark-results.md`, which is
generated — edit the pipeline, not the table.

## Why five corpora and not one

A single corpus measures a single kind of speech. FLEURS is a narrator reading
clean prose in a quiet room; Common Voice is a stranger's laptop microphone in a
kitchen; LibriSpeech and MLS are audiobooks; VoxPopuli is a politician talking
over a noisy chamber with the accent of whichever country sent them. A system
tuned for one can lose badly on another, and a product page quoting only its
best corpus is quoting nothing.

| Corpus | Published | Speech | Languages here |
| --- | --- | --- | --- |
| FLEURS | 2022, Google | read, studio | en fr de es it pt nl pl |
| Common Voice 21.0 | 2025, Mozilla | crowdsourced, consumer microphones | en fr de es it pt nl pl |
| Multilingual LibriSpeech | 2020, Meta | audiobook | fr de es it pt nl pl |
| LibriSpeech test-clean | 2015 | audiobook | en |
| VoxPopuli | 2021, Meta | spontaneous, parliamentary | en fr de es it nl pl |

MLS publishes no English config, so LibriSpeech test-clean — the set English
audiobook results are actually published against — fills that slot. Every
language is therefore measured on four kinds of speech, except Portuguese,
which VoxPopuli does not cover.

Common Voice 21.0 is fetched from the `fsicoli/common_voice_21_0` mirror:
Mozilla emptied its own Hugging Face repository in October 2025. The audio and
transcripts are Mozilla's release; only the hosting differs, and every file is
pinned by SHA-256 on first download.

## What is held identical between the two systems

- **The audio.** Each clip is converted once to 16 kHz mono PCM and frozen with
  a content hash. Both systems read byte-identical files.
- **The reference.** Each corpus's own published human transcript, unedited.
  No reference was written, reviewed, or adjusted by this project.
- **The scorer.** The same Swift implementation and the same normalisation for
  both systems. There is no second normaliser anywhere in the pipeline.
- **The segmentation.** Wispr Flow's collector splits long recordings at
  silences; that is disabled here, so one benchmark clip is one request. Both
  systems see the same audio spans.

## What is deliberately *not* identical

Wispr Flow is told which language the clip is in, because its app exposes that
setting and that is how someone uses it. VoxoL is told nothing and detects the
language itself. This favours Wispr: any VoxoL win is a win against the
stronger configuration of the competitor.

## Sampling

300 clips per corpus and language, chosen by sorting on
`sha256(corpus, language, clip id)` and taking the first 300. This is
reproducible from the identifiers alone — it does not depend on file order,
on a random seed, or on the machine. Clips shorter than 1 s or longer than 30 s
are excluded before sampling: the first are usually a single word with no
context, and the second are segmenter artefacts rather than speech.

Three hundred clips is a median of about 6 900 reference words per cell, but
the spread is wide — 2 045 on Common Voice Portuguese against 12 388 on MLS
Dutch, because the corpora differ in how long an utterance is. A cell with a
third of the words carries a materially wider interval, which is why every
comparison is published with one rather than as a bare number.

## Statistics

Word error rate is micro-averaged — total errors over total reference words —
because that is what the public leaderboards for these corpora report. The
macro average over clips is recorded alongside it in the JSON output.

Differences between the two systems carry a 95% paired bootstrap interval,
10,000 resamples, fixed seed. The resampling unit is the **speaker** — the
sentence for FLEURS, which publishes no speaker id — not the clip: MLS Dutch
draws its three hundred clips from six narrators, and treating each clip as
independent evidence made intervals far too narrow. An external audit caught
that, and re-deciding every cell with clustered resampling plus a
Benjamini-Hochberg correction across the 31 tests moved the record from
15/9/7 to **14 wins, 6 losses, 11 ties**. The per-cell verdicts are generated
into `benchmark-final-verdicts.json` by
`Scripts/rescore-with-clustered-bootstrap.py`.

A benchmark is recorded as a win only where that interval excludes zero.
Everything else is a tie, including differences that look large — Common Voice
Portuguese is 2.74 points apart and still a tie, because one five-word clip
against which Wispr Flow emitted forty extra words carries a quarter of its
errors there.

## Numbers are written the same way on both sides

Wispr Flow writes numbers as digits; these corpora spell them out, and so does
VoxoL. The scorer removes punctuation and casing but has no idea that "598" and
"cinq cent quatre-vingt-dix-huit" are the same thing, so on Common Voice French
— full of street addresses — that convention difference alone cost Wispr Flow
1.3 points of apparent accuracy.

The headline figures therefore come from a second scoring pass in which every
integer is expanded to words, in the benchmark's own language, on the reference
and on both systems' transcripts alike. Applied symmetrically, any quirk of the
expander cancels; what is left is disagreement about what was said rather than
about how to write it.

The scoring under each corpus's own published protocol is kept in the report
beside it, because that is what those corpora's public numbers mean.

## Failures are scored, not dropped

A clip a system returned nothing for is scored as a full deletion rather than
excluded. Dropping it would quietly reward whichever system failed. Per-system
coverage is written next to each report, and a system that wins on word error
rate while returning nothing for part of the set has not won.

## Reproducing

```bash
export HF_TOKEN=<a Hugging Face read token>

# Download, sample, convert, and freeze all 31 benchmarks (~15 GB).
./Scripts/prepare-multilingual-suite.sh /Volumes/0_Oueillez/VoxoL-Benchmarks-Multilingual

# VoxoL, on-device.
./Scripts/run-multilingual-voxol.sh /Volumes/0_Oueillez/VoxoL-Benchmarks-Multilingual

# Wispr Flow, through the signed-in desktop session.
./Scripts/run-multilingual-wispr.sh /Volumes/0_Oueillez/VoxoL-Benchmarks-Multilingual

# Score again with numbers written the same way on both sides.
python3 Scripts/normalize-benchmark-numbers.py \
  --root /Volumes/0_Oueillez/VoxoL-Benchmarks-Multilingual \
  --cli .build/release/voxol-asr-benchmark

# Table and JSON.
python3 Scripts/aggregate-multilingual-benchmark.py \
  --root /Volumes/0_Oueillez/VoxoL-Benchmarks-Multilingual \
  --output Docs/multilingual-benchmark-results.md \
  --json-output Docs/multilingual-benchmark-results.json
```

All of these are resumable and skip work that is already complete, so an
interrupted run continues rather than restarting.

The first download of each upstream file records its SHA-256 in
`cache/download-pins.json`. Later runs verify against that pin and fail loudly
if an upstream file has changed, because a benchmark that silently tracks a
moving dataset stops meaning what its published numbers said it meant.
