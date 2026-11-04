# Launch audit: preregistered experiments

Recorded before the new measurements. Baseline: dirty source snapshot at
`outputs/launch-audit-20260910T073441Z/initial-state.json`. No reserved personal
control is opened. The installed application and model weights remain untouched.

## E1 — Avoid mel extraction for an exact encoder-cache hit

Hypothesis: an existing exact cached encoder tensor makes recomputing its input
features unnecessary. The decoder, its current vocabulary, retry policy, and
confidence calculation must still execute. No approximate matching is permitted.

The candidate is opt-in with `VOXOL_ASR_EARLY_ENCODER_CACHE=1`; baseline uses `0`.
Both variants use the same Release benchmark binary, immutable model, audio hashes,
and `.all` compute configuration. Run variants in ABBA order. Within each process,
alternate warm cache hits and misses. Loading and priming are separate observations.
Use public French/English clips plus previously exposed medium/long personal
diagnostics. Repetition does not create a new independent audio source.

Success gate: all transcript bytes identical between runs and against the uncached
reference, no new failures, at least 5 ms lower cached p50 on the medium/long
scenarios, and no repeatable >5% regression on uncached p50. Tail latency, thermal
state, source count and all failed observations must be reported. Budget: one
implementation and one confirmation campaign. An ambiguous timing gain is not
promoted; the experiment remains disabled or is removed.

This is an ASR file-replay microbenchmark. It cannot establish microphone,
release-to-visible-text, full-product memory or energy improvements. A native
processor replay provides a separate parity check, not an insertion measurement.

## E2 — Make insertion measurements truthful

The existing insertion script compiles its event sender inside the timed region
and kills other VoxoL processes. Replace that probe with a standalone, precompiled
helper, a uniquely owned TextEdit document and monotonic timestamps. Check the
inserted text rather than equating an API return with observation. Missing
Accessibility or Automation permission is a failed/blocked test, not zero latency.
Never reset permissions, close unrelated documents, or replace the installed app.

## E3 — Public evidence and target contracts

Export only public-manifest aggregates and allowlisted provenance. Verify source
identity, complete sample coverage, denominators, finite metrics and report hashes.
Unknown speaker independence means no population confidence interval. Historical
personal AI rewrite-like targets are quarantined from faithful-model selection;
existing human-approval gates are not modified. These changes improve evidence
quality, not ASR accuracy by themselves.

## E4 — Align overlap seams before the truncated window ending

Observed diagnostic errors include mid-word fragments and duplicated suffixes at
long-form boundaries. Current reassembly discards a timestamp-based prefix and
appends the remainder; overlap-token agreement is measured but not used to join.

Candidate: opt-in `VOXOL_ASR_SEAM_ALIGNMENT=1`. Require an exact four-token anchor
inside the overlapping audio, unique within the temporally compatible candidates,
and at most three encoder frames of alignment error. Prefer an anchor near the
overlap midpoint. Replace the previous truncated ending with the current window's
complete continuation. No vocabulary rules or approximate textual substitutions.
Ambiguity preserves the original behavior. Audio is never shortened.

This changes model output and must not be called an exact speed optimization.
Before promotion: re-run all 88 exposed diagnostics and all 40 public clips with
both settings; require lower diagnostic lexical errors, no additional public
errors, no new failures, and inspect every changed number/negation sequence and
every previously correct regression. An independent long-form public regression
is required before enabling by default. A lower score against historical AI
references alone is insufficient evidence. The 60 reserved takes remain unused.

### E4 follow-up, frozen before the constructed-public run

The first run changed three diagnostic transcripts. One apparent regression
removes `m'aider.ider` to `m'aider`, but the historical AI reference itself contains
the duplicated fragment. Both previously recorded challenger outputs omit that
fragment. This is evidence of possible reference contamination, not permission
to rewrite the old ground truth or declare an acoustic correction certain.

The external VoxPopuli SSD is not mounted. Instead, construct sixteen long
stress inputs using the existing forty public clips: groups of 5, 10 and 20 per
language, plus two 20-clip alternating-language inputs. Sort by original public
ID; use 250 ms gaps; concatenate official references. Freeze the recipe, bytes
and constituent groups before running either variant. This tests join robustness,
not natural spontaneous dictation, and remains one shared regression group.
Require no added aggregate lexical errors in each French/English/mixed scenario,
no new failures and manual inspection of all changed critical numeric/negation
sequences. Even success here does not waive the natural long-form launch gate.

## E5 — A larger Qwen ASR challenger, not a production runtime migration

The historical 0.6B Qwen challenger lost on the diagnostic cohort but won on the
English public subset. Test the 1.7B 8-bit conversion to isolate model capacity
without simultaneously lowering quantization precision. Its Apache-2.0 provider
card and MLX support were checked on 2026-09-10. Pin its converted revision and
every downloaded file; the converter's exact upstream revision remains unknown.

Run all 40 existing public and all 88 exposed diagnostic clips, with auto language,
temperature zero, seed 1729 and the existing 2048-token ceiling. No reference
enters generate(). CPU/GPU inference remains on the Mac; no audio upload and no
Python dependency is added to VoxoL. Preparation budget is bounded to 900 seconds
and each cohort to 1800 seconds. Keep failures in the denominator.

A replacement recommendation needs a clear benefit on a relevant subgroup,
no critical-meaning regressions, a viable stop-to-visible latency and native
integration/memory evidence. A private AI-reference win alone is insufficient.
Timing is descriptive unless candidates are alternated under equivalent load.
