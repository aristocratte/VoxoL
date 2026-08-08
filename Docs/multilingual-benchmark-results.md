# VoxoL vs Wispr Flow — multilingual public benchmarks

5 public test sets, 8 languages, 31 benchmarks, 9258 clips.

Both systems transcribed the same frozen audio and were scored by the same scorer against each corpus's own published human reference. Wispr Flow was given the language explicitly, as its app allows; VoxoL detected the language on its own. Word error rate is micro-averaged, as the public leaderboards for these corpora report it.

**Head to head: 13 wins, 8 losses, 10 statistical ties** (a result counts as a win only where the 95% interval on the difference excludes zero).

VoxoL median inference: **115 ms** per clip, on-device.

## Per corpus and language

| Corpus | Language | Clips | VoxoL WER | Wispr Flow WER | Δ (VoxoL − Wispr) | 95% CI | Winner |
| --- | --- | ---: | ---: | ---: | ---: | :---: | :---: |
| FLEURS | English | 300 | 4.73 | 4.00 | +0.72 | [+0.19, +1.27] | Wispr |
| FLEURS | French | 300 | 5.26 | 5.33 | -0.06 | [-0.76, +0.62] | tie |
| FLEURS | German | 293 | 4.44 | 3.65 | +0.79 | [+0.22, +1.37] | Wispr |
| FLEURS | Spanish | 300 | 2.85 | 2.41 | +0.43 | [+0.05, +0.84] | Wispr |
| FLEURS | Italian | 297 | 3.06 | 2.60 | +0.45 | [-0.03, +0.94] | tie |
| FLEURS | Portuguese | 296 | 4.88 | 3.89 | +0.99 | [+0.53, +1.47] | Wispr |
| FLEURS | Dutch | 300 | 7.35 | 6.65 | +0.71 | [-0.10, +1.50] | tie |
| FLEURS | Polish | 300 | 6.86 | 5.24 | +1.63 | [+0.53, +2.59] | Wispr |
| Common Voice 21.0 | English | 300 | 8.54 | 10.30 | -1.76 | [-3.21, -0.43] | **VoxoL** |
| Common Voice 21.0 | French | 300 | 7.28 | 12.28 | -5.00 | [-6.80, -3.30] | **VoxoL** |
| Common Voice 21.0 | German | 300 | 4.55 | 6.67 | -2.11 | [-3.13, -1.14] | **VoxoL** |
| Common Voice 21.0 | Spanish | 300 | 4.13 | 6.05 | -1.93 | [-3.04, -0.90] | **VoxoL** |
| Common Voice 21.0 | Italian | 300 | 4.19 | 7.17 | -2.97 | [-3.89, -2.12] | **VoxoL** |
| Common Voice 21.0 | Portuguese | 300 | 6.06 | 8.80 | -2.74 | [-8.03, +0.39] | tie |
| Common Voice 21.0 | Dutch | 300 | 4.53 | 4.68 | -0.15 | [-1.03, +0.74] | tie |
| Common Voice 21.0 | Polish | 300 | 1.13 | 6.64 | -5.51 | [-7.05, -4.12] | **VoxoL** |
| Multilingual LibriSpeech | French | 300 | 5.15 | 5.29 | -0.14 | [-0.71, +0.43] | tie |
| Multilingual LibriSpeech | German | 300 | 6.94 | 5.35 | +1.59 | [+0.56, +2.74] | Wispr |
| Multilingual LibriSpeech | Spanish | 300 | 4.25 | 4.11 | +0.14 | [-0.52, +0.74] | tie |
| Multilingual LibriSpeech | Italian | 300 | 13.10 | 13.62 | -0.52 | [-1.32, +0.27] | tie |
| Multilingual LibriSpeech | Portuguese | 300 | 6.43 | 6.24 | +0.19 | [-0.34, +0.68] | tie |
| Multilingual LibriSpeech | Dutch | 300 | 10.79 | 8.65 | +2.14 | [+1.53, +2.72] | Wispr |
| Multilingual LibriSpeech | Polish | 300 | 5.93 | 5.14 | +0.79 | [+0.29, +1.29] | Wispr |
| LibriSpeech test-clean | English | 298 | 2.11 | 3.65 | -1.54 | [-2.43, -0.80] | **VoxoL** |
| VoxPopuli | English | 297 | 6.30 | 7.64 | -1.34 | [-2.04, -0.68] | **VoxoL** |
| VoxPopuli | French | 298 | 10.10 | 11.50 | -1.40 | [-1.93, -0.88] | **VoxoL** |
| VoxPopuli | German | 298 | 8.29 | 10.06 | -1.77 | [-2.80, -0.82] | **VoxoL** |
| VoxPopuli | Spanish | 299 | 5.73 | 7.04 | -1.31 | [-2.56, -0.43] | **VoxoL** |
| VoxPopuli | Italian | 291 | 13.52 | 15.95 | -2.44 | [-3.52, -1.45] | **VoxoL** |
| VoxPopuli | Dutch | 296 | 10.43 | 10.95 | -0.52 | [-1.32, +0.25] | tie |
| VoxPopuli | Polish | 295 | 6.38 | 7.24 | -0.85 | [-1.64, -0.17] | **VoxoL** |

## Pooled by language

| Language | Benchmarks | Clips | VoxoL WER | Wispr Flow WER | Δ | 95% CI |
| --- | ---: | ---: | ---: | ---: | ---: | :---: |
| English | 4 | 1195 | 5.03 | 5.84 | -0.81 | [-1.21, -0.45] |
| French | 4 | 1198 | 6.70 | 7.63 | -0.93 | [-1.29, -0.57] |
| German | 4 | 1191 | 6.39 | 6.18 | +0.21 | [-0.30, +0.78] |
| Spanish | 4 | 1199 | 4.35 | 4.77 | -0.43 | [-0.90, -0.04] |
| Italian | 4 | 1188 | 9.85 | 10.99 | -1.14 | [-1.60, -0.69] |
| Portuguese | 3 | 896 | 5.83 | 5.66 | +0.18 | [-0.45, +0.67] |
| Dutch | 4 | 1196 | 9.29 | 8.33 | +0.96 | [+0.58, +1.33] |
| Polish | 4 | 1195 | 5.82 | 5.82 | -0.00 | [-0.41, +0.38] |

## Pooled by corpus

| Corpus | Benchmarks | Clips | VoxoL WER | Wispr Flow WER | Δ | 95% CI |
| --- | ---: | ---: | ---: | ---: | ---: | :---: |
| FLEURS | 8 | 2386 | 4.86 | 4.19 | +0.67 | [+0.45, +0.89] |
| Common Voice 21.0 | 8 | 2400 | 5.13 | 7.85 | -2.72 | [-3.38, -2.17] |
| Multilingual LibriSpeech | 7 | 2100 | 7.50 | 6.86 | +0.64 | [+0.37, +0.90] |
| LibriSpeech test-clean | 1 | 298 | 2.11 | 3.65 | -1.54 | [-2.43, -0.80] |
| VoxPopuli | 7 | 2074 | 8.79 | 10.21 | -1.42 | [-1.79, -1.10] |

## Under each corpus's own published protocol

The same transcripts scored against the reference exactly as the corpus publishes it, with no number normalisation. Wispr Flow writes numbers as digits and these corpora spell them out, so this column charges it for a formatting convention rather than a mishearing — it is here because it is the protocol those corpora are published under, not because it is the fairer comparison of two recognisers.

| Corpus | Language | VoxoL WER | Wispr Flow WER |
| --- | --- | ---: | ---: |
| FLEURS | English | 5.04 | 4.21 |
| FLEURS | French | 5.67 | 5.66 |
| FLEURS | German | 4.55 | 3.80 |
| FLEURS | Spanish | 3.13 | 2.77 |
| FLEURS | Italian | 3.33 | 2.85 |
| FLEURS | Portuguese | 5.10 | 4.29 |
| FLEURS | Dutch | 7.47 | 6.85 |
| FLEURS | Polish | 7.04 | 5.38 |
| Common Voice 21.0 | English | 8.54 | 10.33 |
| Common Voice 21.0 | French | 7.28 | 13.54 |
| Common Voice 21.0 | German | 4.55 | 6.74 |
| Common Voice 21.0 | Spanish | 4.13 | 6.15 |
| Common Voice 21.0 | Italian | 4.19 | 7.34 |
| Common Voice 21.0 | Portuguese | 6.06 | 9.54 |
| Common Voice 21.0 | Dutch | 4.53 | 4.97 |
| Common Voice 21.0 | Polish | 1.13 | 6.64 |
| Multilingual LibriSpeech | French | 5.15 | 5.37 |
| Multilingual LibriSpeech | German | 6.96 | 5.54 |
| Multilingual LibriSpeech | Spanish | 4.26 | 4.16 |
| Multilingual LibriSpeech | Italian | 13.12 | 13.66 |
| Multilingual LibriSpeech | Portuguese | 6.56 | 6.51 |
| Multilingual LibriSpeech | Dutch | 10.80 | 8.65 |
| Multilingual LibriSpeech | Polish | 5.93 | 5.23 |
| LibriSpeech test-clean | English | 2.11 | 3.66 |
| VoxPopuli | English | 6.30 | 8.54 |
| VoxPopuli | French | 10.10 | 12.33 |
| VoxPopuli | German | 8.29 | 10.43 |
| VoxPopuli | Spanish | 5.73 | 7.87 |
| VoxPopuli | Italian | 13.52 | 16.60 |
| VoxPopuli | Dutch | 10.49 | 11.43 |
| VoxPopuli | Polish | 6.38 | 7.71 |

## Method

- 300 clips per corpus and language, selected by a hash of the clip identifier so the sample is reproducible and independent of upstream file order. Clips outside 1–30 s were excluded before sampling.
- Audio converted once to 16 kHz mono PCM and frozen with a content hash; both systems consumed byte-identical files.
- Wispr Flow segmentation disabled: one clip, one request.
- Intervals are paired bootstraps over clips, 10,000 resamples, seed 20260806.
- A clip a system returned nothing for is scored as a full deletion rather than dropped; per-system coverage is recorded beside each report.
- A request that never reached the server is retried rather than scored. Counting a dropped connection as a mishearing would have misreported one benchmark by a factor of three.
- **Statistical caveat**: the intervals in this file resample clips, and clips are not independent — MLS Dutch draws 300 clips from six narrators. The authoritative per-cell verdicts use a speaker-clustered bootstrap with a Benjamini-Hochberg correction and live in `benchmark-final-verdicts.json`; where the two disagree, trust the clustered ones.

## What the tables do not show

**Ties are mostly real ties.** Ten of the thirty-one benchmarks land inside the interval. On most of them the two systems are genuinely within a few tenths of a point. On Common Voice Portuguese they are not: the gap is 2.74 points, but a single five-word clip against which Wispr Flow produced forty extra words carries a quarter of its total errors, and the bootstrap correctly refuses to call a benchmark that one clip decides.

**The two systems fail differently.** VoxoL's errors are substitutions — a word heard wrong. Wispr Flow's worst clips are insertions: continuing past the end of the audio, or repeating a phrase it already transcribed. On short clips that costs far more than a misheard word, which is most of why it loses Common Voice.

