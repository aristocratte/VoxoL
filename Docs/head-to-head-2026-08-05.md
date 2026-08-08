# VoxoL against Wispr Flow — the first fair measurement

Every comparison before this one scored VoxoL against Wispr's own output. That
structurally prevents VoxoL from winning: the best achievable score is
"identical to the teacher, mistakes included", and the 10.31% figure quoted for
months was never an error rate — it was a distance from the teacher.

Both systems were run over the same audio and scored against the same
independent human reference, through the same Swift scorer and the same
normalisation. Wispr's verbatim `raw` endpoint was used rather than its edited
one, because the references are verbatim.

## Accuracy

**FLEURS FR+EN, 1,323 clips, Google reference.**

| | Wispr Flow | VoxoL | Delta |
| --- | ---: | ---: | ---: |
| Overall | 5.2787% | **5.2723%** | −0.006 |
| **French** | 5.8917% | **5.2357%** | **−0.656 (−11.1%)** |
| English | 4.5552% | 5.3155% | +0.760 |

**VoxoL is better than Wispr Flow in French, by 11% relative**, on the market
that justifies a local product. Overall the two are a dead heat. Wispr keeps an
edge on English.

**MediaSpeech FR, 2,498 clips, OpenSLR reference.**

| | Wispr Flow | VoxoL | Delta |
| --- | ---: | ---: | ---: |
| Word error | 19.4758% | 20.1639% | +0.688 |
| Substitutions | 8,669 | **8,580** | −89 |
| Deletions | 6,129 | 6,402 | +273 |
| Insertions | 4,647 | 5,150 | +503 |

Wispr wins here by 3.5% relative — but VoxoL makes *fewer substitutions*, so its
word recognition is not what trails.

**This corpus is a poor judge.** Its references are incomplete and wrong:

```
reference : ici tout le monde vit dans detente côte à côte
VoxoL     : La situation ici, tout le monde vit dans des tentes côte à côte
Wispr     : La situation ici, tout le monde vit dans des tentes côte-à-côte
```

Both systems agree, and the reference omits "la situation" and writes "detente"
for "des tentes". Counting words that VoxoL and Wispr both produce and the
reference lacks: **7,391 of VoxoL's 20,132 scored errors — 36.7% — are reference
defects, not model errors.** Both systems pay that tax, so the comparison stands,
but the absolute numbers do not. Prefer FLEURS.

## Latency

The structural advantage, never quantified before. Same 40 MediaSpeech clips,
timing what a user waits through.

| | p50 | p95 | p99 |
| --- | ---: | ---: | ---: |
| Wispr Flow (cloud round trip) | 3,261 ms | 4,383 ms | 4,641 ms |
| VoxoL (local inference) | 145 ms | 170 ms | 196 ms |
| | **22× faster** | **26× faster** | |

Two caveats, both stated rather than buried:

- the local figure is Core ML inference; end-to-end also runs the Qwen polisher,
  which adds roughly 700 ms at p50, so a fair full-pipeline figure is nearer
  850 ms — still about 4× faster than Wispr's ASR call alone;
- only Wispr's `/llm/asr` was timed. Its LLM edit pass is a second network call
  that was not measured, so its own full pipeline is slower than 3,261 ms.

Six of the 40 requests returned 429 and were excluded from the percentiles; the
probe paced itself at the collector's own 0.35 s spacing and still hit
throttling.

## What this changes

The strategy of chasing Wispr's generic word error is finished, and the reason is
not that it is hard — it is that **it is already done**. Blind adjudication of 60
disagreements split 9 to VoxoL and 7 to Wispr; FLEURS puts them within 0.006
points overall with VoxoL clearly ahead in French.

What remains is not accuracy but reach: distribution, and the personal
vocabulary a cloud service cannot hold without giving up its privacy claim.
