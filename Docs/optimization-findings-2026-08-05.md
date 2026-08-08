# VoxoL optimization findings — 2026-08-05

Four experiments run against the 2026-08-04 candidates. Two changed a decision,
two are negative results worth keeping so nobody spends the day repeating them.

## Polisher v8 is promotable

The Qwen LoRA candidate `full-text-r4-i1200-lr5e-05` passes every gate once they
measure what the plan actually specifies.

| Runtime behaviour | v6 installed | v8 candidate |
| --- | ---: | ---: |
| Protected token recall | 100% | **100%** |
| Model output accepted | 898 / 1382 | **1320 / 1382** |
| Deterministic fallback forced | 484 (35.0%) | **62 (4.5%)** |
| Unexpected word rate | 0.389% | 0.374% |
| Exact match | 57.38% | 58.03% |

The headline is the fallback rate. FidelityKit rejects the installed polisher on
a third of examples and ships the deterministic pass instead; v8 is rejected on
one example in twenty-two. The user gets the language model's benefit eight
times more often. Rejection reasons collapse accordingly — lost protected tokens
fall from 176 to 6, model preambles from 16 to zero.

Raw generation word error drops 90.7% relative (11.541% to 1.104%).

### The gate was measuring the wrong text

`protectedTokenRecallAtLeast99Point5Percent` scored the model's raw generation
and failed v8 at 99.195%. The plan requires "protected spans remain at 100%
**after runtime fallback**", which is a different quantity: the app never ships
raw generation, FidelityKit screens it first. Measured where the plan points, v8
is at 100%.

The gate now runs `voxol-dataset-builder --validate-predictions` — the app's own
validator — and asserts:

- `protectedSpansIntactAfterRuntimeFallback`, the plan's criterion;
- `runtimeAcceptanceDoesNotRegress`, which was absent and is the metric a user
  feels — a candidate could improve word error while being rejected more often;
- `rawProtectedTokenRecallDoesNotRegress`, keeping raw generation as a leading
  indicator without treating it as the shipping bar.

`p95LatencyRegressionAtMost10Percent` was also added: the plan requires p95 to
stay inside the envelope and nothing enforced it.

## Latency measurements do not survive across sessions

The v8 candidate first measured p95 2019.7 ms against a 1587.9 ms baseline, a
27% regression. Re-running the identical adapter over the identical test split
produced **1108.2 ms** — with byte-identical word error, 1.1038% both times, so
it is provably the same model emitting the same text.

An 82% spread on the same work makes any cross-session latency comparison
worthless. The gate is still correct to check p95, and the pipeline does measure
baseline and candidate inside one run, but the two are ~40 minutes apart and
thermal drift is clearly larger than the effect being measured. Treat a latency
verdict as informative only when the regression is large and reproduced.

## Language priming makes the model worse

The v3 vocabulary carries 183 language control tokens; `<|fr|>` is id 71 and
`<|en|>` is 64, both inside the joint's 8,193-wide output. The Swift decoder
never uses them — every utterance starts from blank and the model picks its own
language. That looked like the cause of the English words this model emits mid
French, and like a free fix: no retraining, and the app already knows which
language the user selected.

Measured on MediaSpeech FR, 2,498 clips:

| | Word error |
| --- | ---: |
| Blank start (shipping) | 20.1639% |
| `<|fr|>` primed | 24.1441% |

Priming costs 4 points, 19.7% relative. The TDT predictor was never trained with
those tokens as targets, so seeding one starts the sequence off-distribution.
The experiment is reverted; the finding is recorded in `GreedyTDTDecoder` where
someone would think to try it.

**Language drift is real and needs training signal.** On 5,738 French chunks,
312 (5.4%) contain English function words the teacher does not have — 3,296
parasitic words. Those chunks already carry the correct French target in
training, so more of the same corpus will not fix them; the model has the answer
and does not learn it at four trainable layers. Oversampling them, or adapting
more layers, is the untested lever.

## Text-only adjudication decides a quarter of disagreements

VoxoL and the Wispr teacher disagree on 10.31% of words across 9,509 chunks.
Conventions explain almost none of it: filler words account for 3.4% of the
disagreeing words and contractions 1.3%, leaving 95.3% substantive.

A 60-case pilot, sampled uniformly and adjudicated by three independent agents
without audio:

| Verdict | Count | Share |
| --- | ---: | ---: |
| VoxoL correct | 9 | 15.0% |
| Teacher correct | 7 | 11.7% |
| Both acceptable | 24 | 40.0% |
| Needs the audio | 20 | 33.3% |

The 26.7% decided are trustworthy — each one turns on something the context makes
certain. They independently confirm both statistical findings: VoxoL wins on
technical vocabulary (the teacher writes "Piton" for Python, "cloud code" for
Claude Code, "Pirouette" for Pyroute2, "Django en Viron" for django-environ) and
loses on language drift ("It's très bête" inside French, "WSJI" for WSGI).

**`both_ok` is not reliable.** Cross-checking those 24 against the actual word
differences shows the agents identify one visible convention difference —
`gonna`/`going to`, `asyncio`/`async io`, `2.4`/`two point four` — then
generalise it to the whole passage while missing other substantive divergence.
Harmless, since `both_ok` yields no label, but it must not be read as "40% of
disagreements do not matter". Scaling this should drop the category and force a
choice between the two transcripts or abstention.

Cost: roughly 2,500 subagent tokens per case.

## What is not blocked by anything technical

The ASR candidate beats the installed runtime on every frozen benchmark and
holds Core ML parity. It cannot ship because `Models/manifests/runtime-models.json`
pins the artifact to a third-party provider revision with per-file hashes;
publishing the new package at an immutable revision is an account-holder action.
