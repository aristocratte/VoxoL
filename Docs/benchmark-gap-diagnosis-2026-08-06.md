# Why VoxoL loses FLEURS and MLS

VoxoL wins Common Voice, VoxPopuli and LibriSpeech against Wispr Flow and loses
FLEURS and MLS. Four things could have explained that, and this is the record of
testing all four. None of them survived, which matters more than it sounds: it
means there is no configuration fix waiting to be found, and effort spent
looking for one is wasted.

Every measurement below is on the same 31 frozen benchmarks, 9 258 clips, scored
by the same scorer.

## 1. Quantisation — ruled out

The shipped runtime is INT8 linear per-channel. An FP16 build of the same
weights already existed, so the cost was directly measurable on the eleven
benchmarks where it mattered most.

| | mean | worst |
| --- | ---: | ---: |
| INT8 vs FP16, same backend | **+0.041** | 0.20 |
| Neural Engine vs GPU, same weights | **−0.012** | 0.10 |

The gaps to explain run from +0.43 to +2.14. Quantisation is one to two orders
of magnitude too small. Worth recording as a positive result in its own right:
INT8 is essentially free, and it is what holds inference at 115 ms on the ANE.

An FP16 build of this graph fails on the Neural Engine with CoreML error −9 and
has to run on the GPU; that is why the backend was measured separately rather
than assumed.

## 2. Clip duration — ruled out, and it looked convincing

Pooled across all corpora, the story was clean: VoxoL wins short clips and loses
long ones, which would have pointed at the TDT decoder's windowing.

| band | VoxoL | Wispr | gap |
| --- | ---: | ---: | ---: |
| 0–5 s | 7.50 | 9.95 | −2.45 |
| 5–10 s | 5.83 | 6.96 | −1.14 |
| 10–15 s | 6.64 | 6.22 | +0.42 |
| 15–20 s | 6.99 | 6.88 | +0.10 |

Split by corpus, the effect vanishes. VoxoL wins at *every* duration on
VoxPopuli, Common Voice and LibriSpeech, and loses at *every* duration on FLEURS
and MLS. Short clips are mostly the corpora it wins; long clips are mostly the
corpora it loses. The trend was composition, not duration — Simpson's paradox.

This one is worth remembering as a method note: the pooled table would have sent
a day of work into the decoder for nothing.

## 3. Catastrophic forgetting — ruled out, and the sign is reversed

The shipped model is stock Parakeet TDT 0.6B v3 plus a delta trained only on
French and English. The obvious suspicion was that the delta degraded the six
languages it never saw.

Stock weights were exported through the same script, the same quantisation and
the same compute units — a zero-valued delta, so the only variable is the
training — and run over all 31 benchmarks.

| | mean gap | fine-tune helps / hurts |
| --- | ---: | --- |
| trained languages (fr, en) | **+0.003** | 3 / 3 |
| never-seen languages | **−0.101** | 13 / 4 |
| FLEURS | −0.241 | 8 / 0 |
| MLS | −0.199 | 6 / 0 |
| Common Voice | +0.118 | 1 / 5 |

No forgetting: the delta helps the untrained languages slightly, and helps
FLEURS and MLS specifically — the two corpora VoxoL loses. It is simply an order
of magnitude too small to close them.

The uncomfortable half of the same result: **on French and English, the
languages it was trained on, the delta is worth +0.003 — nothing.**

Formatting was checked before concluding, because the distillation targeted
Wispr's *written* style and word error rate normalises punctuation and casing
away. Common Voice is the only corpus here with a cased, punctuated reference:

| | exact match | punctuation agrees | initial capital |
| --- | ---: | ---: | ---: |
| stock | 52.79 % | 95.88 % | 95.79 % |
| fine-tuned | 52.92 % | 95.83 % | 95.83 % |

0.13, −0.05 and 0.04 points. There is no hidden formatting gain either.

## 4. What the remaining errors actually are

Words VoxoL gets wrong that Wispr gets right, on the four worst benchmarks:

| | mls-nl | mls-de | fleurs-pl | fleurs-pt |
| --- | ---: | ---: | ---: | ---: |
| ordinary word confused | 59.3 % | 59.2 % | 54.3 % | 58.0 % |
| inflection / ending | 22.0 % | 17.1 % | 21.4 % | 13.0 % |
| omission | 13.8 % | 14.7 % | 14.8 % | 24.4 % |
| long / compound word | 4.5 % | 8.4 % | 8.1 % | 2.3 % |
| diacritic | 0.4 % | 0.6 % | 1.4 % | 2.3 % |

The errors are acoustic-phonetic, not lexical: `zit`/`ziet`, `teilt`/`heilt`,
`tritt`/`trit`, `miedź`/`mieć` — minimal pairs separated by one short vowel. The
three languages lost outright (nl, de, pl) are also the most inflected, and
inflection accounts for a fifth of the difference.

One mechanically distinctive pattern, small but specific: long compounds lose
their *front*, not their tail — `hindurchzukommen`→`kommen`,
`infravermelho`→`vermelho`, `gwiazdozbiorze`→`zbiorze`,
`achtereenvolgens`→`volgens`.

Caveat: MLS and FLEURS publish lower-cased references, so proper nouns carry no
case signal and fall under "ordinary word confused". The category counts are a
lower bound on names, not a partition — `schwarzenegger`→`schnacker` and
`dunlap`→`danelay` are in there.

## Conclusion

The gap on FLEURS and MLS is in the base model, not in anything this project
did to it. Stock Parakeet loses those corpora too, slightly worse. There is no
quantisation setting, compute unit, decoder window or language routing that
recovers it.

The two levers that remain are a stronger base model, or substantially more
Dutch, German and Polish audio — a different order of budget, and worth deciding
deliberately rather than drifting into.

What should *not* absorb more effort: the Wispr distillation recipe. Five
training hypotheses were tested earlier and all came back negative, and the
delta that recipe produced is now measured at zero on its own target languages.

---

# Second pass: what was tried to close the gap

## Language-model fusion — ruled out before building it

The error taxonomy said a fifth of the exclusive errors were inflections, which
is language-model territory. Before building an n-gram over the subword
vocabulary and a prefix-conditioned scorer in the decode loop, the premise was
checked directly: on the clips VoxoL lost, is the human reference more probable
than VoxoL's transcript?

| | reference preferred |
| --- | ---: |
| mls-nl | 3.0 % |
| mls-de | 12.9 % |
| fleurs-pl | 23.0 % |
| fleurs-en | 48.7 % |

Measured twice — once with the installed French polisher, once with a neutral
Qwen2.5-0.5B in case the polisher was biased — with the same answer. A language
model would have pushed *away* from the reference in three languages out of
four.

The reason is in the taxonomy: `zit`/`ziet`, `waarde`/`waarden`,
`teilt`/`heilt` are all real words. The acoustic model does not emit
implausible text that a language model would repair; it emits **plausible text
that is wrong**, which is the one case a language model cannot detect.

This also weakens beam search, whose gain over greedy comes from rescuing
low-confidence near-ties. These are confident substitutions.

## The vocabulary boost was making dictation worse

The decoder's vocabulary boost added a flat offset to every subword piece of
every term. Tokenised, `humpback` is `▁h` + `ump` + `b` + `ack` — and `▁h`,
`b` and `ack` occur inside thousands of unrelated words. Sixty terms produced
thirty boosted pieces, most of them generic fragments.

Measured on FLEURS English:

| | WER |
| --- | ---: |
| no vocabulary | **5.04** |
| flat boost — what shipped | **5.71** |
| trie-scoped contextual bias | 5.10 |

Split by clip, the flat boost hurt the clips that *contained* the terms
(+0.55) as much as those that did not (+0.78). Any user who filled their
dictionary was degrading their own transcription.

`ParakeetContextualBias` replaces it: a term's pieces are encouraged only where
the decoder is already spelling that term, entry pieces weakly and
continuations strongly. A weight sweep (entry 0/1/2, continuation 6/12) never
beat the no-vocabulary baseline on FLEURS, which is the honest result for a
sixty-word generic list where each term appears in one or two clips of three
hundred. What it does deliver is safety: the shipped behaviour cost 0.67
points, this costs 0.06.

The feature's real test is a vocabulary that matches the speaker's own speech,
which no public corpus provides.

## The benchmark and the product disagree, measurably

The suite scored the recogniser alone — `rawText` and `finalText` were the same
string on all 9 258 clips. With the deterministic layer, the fast-path gating
and the polisher wired in, the product scores:

| | ASR only | full product |
| --- | ---: | ---: |
| Common Voice FR, as published | 6.97 | 8.91 |
| Common Voice FR, number convention neutralised | 6.97 | **7.07** |

The 1.94-point penalty was 95 % a writing convention: these corpora spell
numbers out and the product writes digits, because `B450` dictated as "B quatre
cent cinquante" is what made real use unbearable. Across seven French and
English benchmarks with the convention neutralised on both sides, the product
chain costs **+0.09 points on average** — the polisher is doing formatting work
word error rate cannot see, not damaging accuracy.

The consequence is worth stating plainly: on numbers, **the benchmark rewards
exactly the behaviour that makes the product worse**. Optimising the published
score there would be optimising against the user.

## A stronger base model — measured, and the ratio is bad

Only one published model covers the languages being lost. `parakeet-tdt-1.1b`
is English only; `canary-1b-v2` covers all twenty-five European languages.
Applying NVIDIA's own published FLEURS gains to the gaps measured here:

| cell | our gap | canary gain | after |
| --- | ---: | ---: | ---: |
| fleurs-nl | +0.71 | +1.36 | **−0.65** |
| fleurs-es | +0.43 | +0.55 | **−0.12** |
| fleurs-fr | −0.06 | +0.13 | **−0.19** |
| fleurs-de | +0.79 | +0.64 | +0.15 |
| fleurs-en | +0.72 | +0.35 | +0.37 |
| fleurs-it | +0.45 | −0.07 | +0.52 |
| fleurs-pt | +0.99 | +0.37 | +0.62 |
| fleurs-pl | +1.63 | +0.67 | +0.96 |

Three cells of eight flip. The other five stay lost.

The price is the runtime. Canary is an attention encoder-decoder, not a
transducer: the Core ML export, the decode loop, the parity harness and the
confidence signals are all built around frame-synchronous TDT decoding, and
autoregressive decoding with a KV cache replaces all of it. The model is
roughly twice the size. The 115 ms that makes VoxoL twenty-two times faster
than its competitor would not survive intact.

Three benchmark cells against the clearest product advantage there is.

## Nothing is wrong with these languages

Before buying training data for Dutch, German and Polish, the obvious question:
are those languages weak, or is something else going on?

| language | Common Voice | VoxPopuli | FLEURS | MLS |
| --- | ---: | ---: | ---: | ---: |
| Dutch | **−0.15** | **−0.52** | +0.71 | +2.14 |
| German | **−2.11** | **−1.77** | +0.79 | +1.59 |
| Polish | **−5.51** | **−0.85** | +1.63 | +0.79 |

Negative is VoxoL ahead. The pattern is identical in all three: **VoxoL beats
Wispr Flow on consumer microphones and on spontaneous speech, in every one of
the languages it supposedly loses**, and loses only on studio-read prose and
audiobooks. Polish Common Voice is a 5.5-point win.

So there is no Dutch problem, no German problem and no Polish problem. Buying
Common Voice training audio for them would add data from the domain where they
already win. The domain where they lose is audiobook and studio narration —
which means the only training data that would move those numbers is MLS and
FLEURS themselves. That is benchmaxxing by definition, and it buys a domain no
dictation user is ever in.

## Where the whole suite actually lands

| domain | VoxoL wins | Wispr wins | ties | mean gap |
| --- | ---: | ---: | ---: | ---: |
| consumer microphones | 6 | 0 | 2 | **−2.77** |
| spontaneous speech | 6 | 0 | 1 | **−1.38** |
| audiobook | 1 | 3 | 4 | +0.33 |
| studio-read prose | 0 | 5 | 3 | +0.71 |

**Twelve of fifteen cells of real speech go to VoxoL, none to Wispr Flow.** The
entire deficit sits in prepared, read material — someone narrating a book or
reading prose in a treated room.

Nobody dictates that way. Closing that deficit means optimising for the one
condition the product is never used in, at the cost of the latency and the
personalisation that define it. The remaining work worth doing is what real use
exposed — numbers written as digits, a vocabulary boost that does not corrupt
neighbouring words, and a benchmark built from the user's own speech — not
another point on FLEURS.

---

# Third pass: an external audit, and what it broke

An independent review of this document found five arithmetic inconsistencies.
Four were real. They are recorded here because the pattern matters more than any
one of them: every one came from assembling a table by hand instead of
generating it, and none would have survived an assertion.

| audit finding | verdict |
| --- | --- |
| 9 258 clips ≠ 31 × 300 | correct. Eleven cells lose clips to the duration filter, applied while preparing audio and therefore before any system saw it — no selection effect, but undocumented. |
| head-to-head 14/9/8 vs a domain table summing to 13/8/10 | correct, and worse than reported: the results file held 13/8/10 and the true post-extension figure was 15/9/7. The count had been done mentally and never regenerated. |
| the confidence figures imply a 24 % base error rate | correct, and the most damaging. The word comparison did not strip punctuation, so `nab.` never matched `nab` and every sentence-final word counted as an error. True base rate **6.0 %**; precision at the 20th percentile **23.2 %**, not the 65.6 % reported. |
| 3261 / 115 = 28.4×, not 22× | correct. The 22× carried over from a superseded 145 ms median. |

`Scripts/verify-benchmark-consistency.py` now regenerates every published figure
from the frozen manifests and the scored reports, and asserts that the domain
table sums to the global record and that cell counts sum to the clip total.

## The intervals were too narrow, and it changes four verdicts

The audit's central methodological point: the clip is not the independent unit.
Checking the manifests bore it out — MLS Dutch draws 300 clips from **six**
narrators, one supplying 46 % of them, and FLEURS records the same sentence
1.3 times on average.

Resampling clusters (speaker where published, sentence for FLEURS, whose
transcript file carries no speaker id) and applying a Benjamini-Hochberg
correction across the 31 cells:

An earlier revision of this table compared a clip-level count that *included*
the five extended cells against a clustered count that *excluded* them — two
different cell sets in two columns. Same-basis figures, every cell at its best
available sample:

| all 31 cells, extended superseding | clip bootstrap | clustered + BH |
| --- | ---: | ---: |
| VoxoL wins | 15 | **14** |
| competitor wins | 9 | **6** |
| ties | 7 | **11** |

Three losses and one win were sampling noise: `fleurs-es`, `mls-de` and
`mls-pl` stop being losses, `mls-it` stops being a win, and `fleurs-fr`'s
apparent dead heat stays a tie. The five decided losses that remain are
`fleurs-de`, `fleurs-en`, `fleurs-nl`, `fleurs-pl`, `fleurs-pt` and `mls-nl`.

| domain | VoxoL | competitor | ties |
| --- | ---: | ---: | ---: |
| consumer microphones | 6 | 0 | 2 |
| spontaneous | **7** | 0 | 0 |
| audiobook | 1 | 1 | 6 |
| studio-read | 0 | 5 | 3 |

Per-cell verdicts, intervals and p-values are generated into
`Docs/benchmark-final-verdicts.json` by
`Scripts/rescore-with-clustered-bootstrap.py`; the tables above are copies of
that output, not hand assembly.

## The framing was wrong, and I withdraw it

The audit's strongest point needs no statistics: **Common Voice is a read-speech
corpus.** Mozilla's own description is "read sentences aloud". The claim that
"the entire deficit is in prepared, read material" is therefore false on its
face — the corpus VoxoL wins most decisively is also read speech.

Worse, three of the four "domains" rest on a single corpus each, so a FLEURS
effect is indistinguishable from a text-difficulty effect, a proper-noun-density
effect, a subword-fragmentation effect, a reference-quality effect or a
training-exposure effect. Attributing the residue to speaking style was not
earned.

What the data supports is narrower and should replace it:

> Relative performance varies strongly by corpus. These data show no uniform
> per-language weakness, but they do not attribute the variation to reading
> versus speaking, and they do not predict dictation performance.

Corollaries that also fall: "only training on those corpora would move them" is
unfounded — better modelling of rare words, inflection or long subword sequences
could generalise there. And after several rounds of taxonomy and manual
inspection, these 9 258 clips are now a **diagnostic set, not a held-out test**.

## One audit hypothesis tested and not confirmed

The audit proposed that a word scored as the minimum margin over its subword
pieces is mechanically biased against heavily fragmented words — which are
exactly the proper nouns that dominated the flagged set.

The mechanism is real: median margin falls from 7.90 at one piece to 3.00 at
five, while the error rate rises from 2.4 % to 10.1 %. But stratifying the
threshold by piece count — the remedy the mechanism implies — is *worse* at
every operating point (21.1 % precision at the 20th percentile against 23.2 %).
Fragmentation is not only a nuisance; a heavily split word is genuinely more
error-prone, and the raw margin already carries both signals.

The binding constraint is elsewhere: precision peaks near **39 %** at the most
conservative threshold. Three flagged words in five are correct even there,
which is why a repair pass had three chances to break for every one to fix.

## The fifth hypothesis, answered by construction

The audit's strongest procedural point was that none of the four diagnostics
isolated the second stage — a cleanup model that rewrites text could introduce
the FLEURS/MLS gap after recognition, in which case replacing the acoustic model
would answer the wrong question.

It cannot have. Across all 31 benchmarks, **9 258 clips of 9 258 have
`finalText` identical to `rawText`**: the head-to-head ran the recogniser alone.
The gap is acoustic by construction.

The other half of that ablation — the language hint, given to the competitor and
withheld from VoxoL — is now switchable. Measured on the four French cells:

| | no hint | French hint |
| --- | ---: | ---: |
| commonvoice-fr | 7.28 | **7.04** |
| fleurs-fr | 5.67 | **5.50** |
| mls-fr | 5.15 | **5.03** |
| voxpopuli-fr | 10.10 | 10.30 |

Helps three cells, costs one, about 0.1 point on average. Small, but it confirms
the handicap was real rather than rhetorical: the published comparison gave the
competitor an advantage worth roughly two tenths of a point on read French.

## Chasing the confound down to a mechanism

The audit asked for a measurement separating "domain" from everything else that
differs between these corpora. Two were testable from the existing data, holding
language fixed and comparing FLEURS with Common Voice.

**Subword fragmentation does not explain it.** Stratifying clips on pieces per
word — the tokenizer's own measure of unusual vocabulary — the gap persists in
all four strata, in all three languages tested.

**Clip length does not explain it either.** In the overlapping band where both
corpora have clips, French 14–20 words gives −0.96 on FLEURS against −4.10 on
Common Voice; Dutch 14–20 gives +1.64 against −2.54.

But the numbers point at a reframing. On Common Voice, VoxoL is not unusually
good — **the competitor is unusually bad**: 12.28 % on French Common Voice, where
published systems sit around 8–10 %. Splitting every error by utterance length
across all corpora:

| clip length | VoxoL insertions | competitor insertions |
| --- | ---: | ---: |
| 0–10 words | 1.13 % | **2.27 %** |
| 10–16 words | 0.57 % | **1.04 %** |
| 16–24 words | 0.94 % | 0.97 % |
| 24+ words | 0.95 % | 1.12 % |

The competitor invents twice as many words as VoxoL on short utterances, and
the difference disappears on long ones. Substitutions and deletions follow the
same curve — 8.37 % against 6.17 % on the shortest clips, 5.55 % against 5.70 %
on the longest, where it edges ahead.

That is a mechanism rather than a label: a cloud pipeline that over-generates
when given little audio. Common Voice clips run 9–10 words; FLEURS and MLS run
21–26.

It should not be over-claimed. The earlier per-corpus duration analysis showed
the corpus effect surviving at fixed audio duration, so length explains part of
the pattern and not demonstrably all of it. What can be said is narrower than
the withdrawn framing and better supported: **the competitor degrades on short
utterances, VoxoL does not, and the corpora VoxoL wins are the ones made of
short utterances.**


---

# Fourth pass: a code review of the whole effort

A model change invited a fresh review of everything above. Four defects
survived every earlier check.

**The corrected table itself was wrong.** The third-pass comparison put a
clip-level count *with* the five extended cells next to a clustered count
*without* them — two cell sets presented as one. Fixed above; the honest final
record is **14 / 6 / 11**.

**The clustered bootstrap depended on a temp file.** FLEURS sentence clusters
lived in `/tmp`; after a reboot the script would have silently fallen back to
one cluster per FLEURS cell, collapsing those intervals to a point and making
every FLEURS cell spuriously decisive. The derivation now lives inside the
script, and a cell that cannot be clustered is excluded from the record rather
than counted.

**The number formatter converted place names.** `Trois-Rivières` became
`3-Rivières`, `Deux-Sèvres` became `2-Sèvres` — real French toponyms open with
number words. A bare hyphen at the edge of a number run now ends the
conversion; hyphens inside a genuine number (`trente-deux`) still convert.

**Digits minted after protection reached the model bare.** `protect()` wraps
native digits in placeholders before the polisher sees the text, but the
formatter runs *after* protection, so the digits it creates — `B450`, `2026` —
were exposed to the model with nothing auditing their survival. They are now
wrapped in the same placeholder scheme, so the fidelity validator's
placeholder count covers them.

**And one omission**: the shadow repair logger existed, was tested, and was
never called — the claim that real dictations were accumulating evidence was
false until this pass wired it into the dictation coordinator (Parakeet
results only, suppressed in private mode, capped at five megabytes).
