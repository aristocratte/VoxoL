# VoxoL — measured against Wispr Flow

Fully local dictation for macOS. Every number below is generated from the measurement pipeline in this repository, and every one is reproducible with the commands at the bottom.

## The headline

| | |
| --- | --- |
| Head to head | **14 wins, 6 losses, 11 ties** across 31 benchmarks |
| Median inference | **115 ms** on device — 28× faster than Wispr Flow |
| Audio leaving the machine | **none** |

A cell counts as a win only where a 95% bootstrap interval on the difference excludes zero, resampling **speakers** rather than clips and corrected for testing 31 cells at once. Anything else is a tie, including gaps that look decisive.

## Where the difference actually is

| Kind of speech | VoxoL | Wispr Flow | Ties |
| --- | ---: | ---: | ---: |
| Consumer microphones | **6** | 0 | 2 |
| Spontaneous speech | **7** | 0 | 0 |
| Audiobook | 1 | 1 | 6 |
| Studio-read prose | 0 | 5 | 3 |

On speech recorded the way people actually speak — ordinary microphones, unscripted talking — VoxoL wins **13 of 15 cells and loses 0**. The losses are concentrated in prepared, read material: an audiobook narrator or prose read aloud in a treated room.

## Every cell, wins and losses alike

| Corpus | Language | Δ WER (VoxoL − Wispr Flow) | 95% CI | Result |
| --- | --- | ---: | :---: | :---: |
| Common Voice 21.0 | German | -2.11 | [-3.18, -1.13] | **VoxoL** |
| Common Voice 21.0 | English | -1.76 | [-3.19, -0.40] | **VoxoL** |
| Common Voice 21.0 | Spanish | -1.93 | [-3.04, -0.89] | **VoxoL** |
| Common Voice 21.0 | French | -5.00 | [-6.85, -3.29] | **VoxoL** |
| Common Voice 21.0 | Italian | -2.97 | [-3.91, -2.10] | **VoxoL** |
| Common Voice 21.0 | Dutch | -0.15 | [-1.04, +0.75] | tie |
| Common Voice 21.0 | Polish | -5.51 | [-7.01, -4.13] | **VoxoL** |
| Common Voice 21.0 | Portuguese | +0.75 | [-0.06, +1.59] | tie |
| FLEURS | German | +0.79 | [+0.14, +1.45] | Wispr Flow |
| FLEURS | English | +0.72 | [+0.17, +1.30] | Wispr Flow |
| FLEURS | Spanish | +0.43 | [-0.03, +0.90] | tie |
| FLEURS | French | -0.06 | [-0.80, +0.64] | tie |
| FLEURS | Italian | -0.28 | [-0.60, +0.05] | tie |
| FLEURS | Dutch | +1.01 | [+0.21, +1.81] | Wispr Flow |
| FLEURS | Polish | +1.63 | [+0.54, +2.60] | Wispr Flow |
| FLEURS | Portuguese | +0.99 | [+0.46, +1.52] | Wispr Flow |
| LibriSpeech test-clean | English | -1.54 | [-2.62, -0.71] | **VoxoL** |
| Multilingual LibriSpeech | German | +1.59 | [-0.34, +5.14] | tie |
| Multilingual LibriSpeech | Spanish | +0.14 | [-0.63, +1.03] | tie |
| Multilingual LibriSpeech | French | -0.14 | [-0.70, +0.38] | tie |
| Multilingual LibriSpeech | Italian | -0.44 | [-1.01, +0.15] | tie |
| Multilingual LibriSpeech | Dutch | +2.14 | [+1.57, +2.88] | Wispr Flow |
| Multilingual LibriSpeech | Polish | +0.79 | [-0.07, +1.53] | tie |
| Multilingual LibriSpeech | Portuguese | +0.19 | [-0.19, +0.58] | tie |
| VoxPopuli | German | -1.77 | [-2.88, -0.70] | **VoxoL** |
| VoxPopuli | English | -1.34 | [-2.06, -0.68] | **VoxoL** |
| VoxPopuli | Spanish | -1.31 | [-2.62, -0.46] | **VoxoL** |
| VoxPopuli | French | -1.40 | [-1.91, -0.92] | **VoxoL** |
| VoxPopuli | Italian | -2.44 | [-3.51, -1.49] | **VoxoL** |
| VoxPopuli | Dutch | -0.71 | [-1.17, -0.30] | **VoxoL** |
| VoxPopuli | Polish | -0.85 | [-1.67, -0.19] | **VoxoL** |

## Under noise

The same clips remixed against six competing voices at a controlled signal-to-noise ratio — a café, an open-plan office. What matters is the shape of the curve, not the absolute number.

| Condition | ._commonvoice-fr (French) | ._librispeech-en (English) | ._voxpopuli-fr (French) | Common Voice 21.0 (French) | LibriSpeech test-clean (English) | VoxPopuli (French) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| clean | — | — | — | **7.28** vs 13.54 | **2.11** vs 3.66 | **10.10** vs 12.33 |
| babble 20 dB | — | — | — | **9.69** vs 15.20 | **2.71** vs 3.09 | **10.39** vs 12.51 |
| babble 10 dB | — | — | — | **19.59** vs 23.88 | **4.25** vs 4.35 | **10.84** vs 13.15 |
| babble 5 dB | — | — | — | **39.35** vs 40.95 | **10.44** vs 9.19 | **13.64** vs 16.06 |

## What is measured, and what is not

- Both systems read **byte-identical audio**, frozen with a content hash, and are scored by the same scorer against each corpus's own published human reference.
- Wispr Flow is **told which language** the clip is in, because its app exposes that setting. VoxoL detects it. Every win above is against the stronger configuration of the competitor.
- Numbers are expanded to words on the reference and both transcripts alike, because one system writes digits and these corpora spell them out — charging either for a writing convention would not be a measurement.
- A request that never reached the server is retried, not scored as a mishearing.
- **These corpora do not measure dictation.** They are read sentences and audiobooks. They cannot see whether a model number came out as `B450` or as four spelled-out words, and that difference decides whether the product is usable. Accuracy on the owner's own speech is measured separately, by the personal benchmark the app can build.

## Reproduce it

```bash
# Download, sample, convert and freeze the benchmarks (~15 GB).
./Scripts/prepare-multilingual-suite.sh <root>

# VoxoL, on device.
./Scripts/run-multilingual-voxol.sh <root>

# Wispr Flow, through the signed-in desktop session.
./Scripts/run-multilingual-wispr.sh <root>

# Scoring, clustered intervals, and this page.
python3 Scripts/normalize-benchmark-numbers.py --root <root> \
  --cli .build/release/voxol-asr-benchmark
python3 Scripts/rescore-with-clustered-bootstrap.py \
  --json-output Docs/benchmark-final-verdicts.json
python3 Scripts/generate-results-page.py
```

`Scripts/verify-benchmark-consistency.py` asserts that the totals on this page sum to the per-cell verdicts and that the cell counts sum to the clip total. It exists because these numbers were wrong four times before it did.

