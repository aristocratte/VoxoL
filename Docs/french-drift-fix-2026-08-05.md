# French language drift — cause, fix, and what is left

On French audio this model sometimes emits English function words mid-sentence.
It is VoxoL's only measured accuracy defect against the Wispr teacher, and it
lands squarely on the French market that justifies a local product.

## Size of the defect

Across 5,738 French chunks in the 2026-08-03 campaign corpus, **312 (5.4%)
contain English function words the teacher does not have — 3,296 parasitic
words**. Independent confirmation came from blind adjudication, which caught
"It's très bête" inside otherwise-French speech.

Those chunks already carry the correct French target in training. The model has
the answer in front of it and does not apply it at four trainable encoder
layers, so more of the same corpus will not fix it.

## What did not work

**Priming a language control token.** The v3 vocabulary carries 183 of them —
`<|fr|>` is id 71 — inside the joint's 8,193-wide output, and the decoder starts
every utterance from blank instead. Seeding `<|fr|>` moved MediaSpeech FR from
20.1639% to 24.1441%, a 19.7% relative regression: the TDT predictor never saw
those tokens as targets, so seeding one starts the sequence off-distribution.

## What works: a language-conditioned logit penalty

Tokenising the corpus with the shipped BPE vocabulary gives per-token language
statistics. **136 tokens occur at least 200 times in English references and are
more than 60× rarer in French** — `▁the` appears 14,098 times in English against
28 in French, `▁that` 8,395 against 9. Those are exactly the drift words.

The decoder now subtracts a penalty from those logits before the argmax when
French is selected. It is a penalty and not a mask on purpose: `▁the` does occur
28 times in genuine French speech, when someone quotes or code-switches, so a
strong enough acoustic signal must still win.

Swept on the 312 affected chunks:

| Penalty | Parasitic English words | Chunks still drifting | Word error |
| ---: | ---: | ---: | ---: |
| 0 | 3,296 | 312 | 72.100% |
| 2 | 2,994 | 269 | 70.791% |
| 5 | 2,295 | 251 | 69.489% |
| 8 | 1,631 | 244 | 69.224% |
| **12** | **691** | **227** | **68.758%** |

At 12 logits, **79% of the parasitic English words are gone** and word error on
the affected chunks drops 3.34 points. The benefit was still climbing; the cost
had flattened.

The cost falls on French audio that was not drifting:

| Penalty | MediaSpeech FR | Cost |
| ---: | ---: | ---: |
| 0 | 20.1639% | — |
| 5 | 20.2520% | +0.088 |
| 12 | 20.2871% | +0.123 |

Weighted over the corpus — 5.4% of chunks gaining 3.34 points, the rest paying
0.123 — the net is about **0.06 points better**, and the perceptual gain is far
larger than that: an English word in the middle of a French sentence is a
visible defect, 0.12 points of word error is not.

### A benchmark that hid the result

The first measurement used MediaSpeech FR alone and showed only the cost, so the
fix looked like a regression. MediaSpeech is French broadcast media and barely
code-switches, so it has almost no drift to repair — the penalty could only add
noise there. The defect lives in conference audio where speakers genuinely move
between languages. **Measure a fix on the population it targets.**

## Gating is not optional

The suppressed tokens are English function words. Applying this to English
dictation would suppress most of a transcript.

`GreedyTDTDecoder.languagePenalty(forLanguageCode:modelsRoot:amount:)` returns
nil for anything that is not French, and the shipped list lives beside the model
in `language-penalty.json`. A caller that does not know the user's language must
pass nil and accept the drift. The app already routes an explicit French or
English choice, so it can supply the code; `Auto` must not.

## What is left

The penalty removes 79% of the drift, not all of it, and it works at decoding
time rather than fixing the model. The remaining 21% needs training signal:
oversampling these 312 chunks, or adapting more than four encoder layers. Both
need a GPU run.
