# Owner pipeline gate

This gate separates raw speech recognition errors from final text-processing
errors on the same live dictations. It is a development diagnostic, not an
independent benchmark.

## Run

1. Launch the development build with the selected ASR candidate.
2. Open **Dictation → Pipeline inspector**, enable **Compare raw and final
   text**, then click **Clear**.
3. Dictate the 19 items from `Docs/owner-pipeline-gate-texts.md` once, in their
   stored order.
4. Click **Copy comparisons**.
5. Run:

   ```sh
   ./Scripts/score-owner-pipeline-clipboard.sh
   ```

The app retains at most 20 comparisons in memory and discards them when it
quits. The scoring wrapper uses a temporary directory, prints only the summary
and failing items, and removes the copied traces and report when it exits.
Private mode disables capture.

## Interpretation

- `rawASR` compares Parakeet output with what was spoken.
- `finalText` compares the inserted text with the desired cleaned text.
- `textProcessingImpact` compares raw and final text against the same clean
  target.
- `qwen_regression` and `deterministic_regression` identify which processing
  route removed or corrupted a critical span that existed in raw ASR output.
- `asr_inherited_failure` means the critical span was already wrong in raw ASR
  and remained wrong in the final text.
- `qwen_repair` and `deterministic_repair` mean the corresponding route
  recovered a critical span that the raw output did not match.

The gate passes only when
`zeroProcessingCriticalRegressionPassed` is true. WER should still be compared
by group because the English and technical slices are deliberately harder than
the general French slice.
