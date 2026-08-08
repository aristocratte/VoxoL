# Wispr teacher review

Start or resume the local review with:

```bash
/Users/aris/Documents/Zphyr/Scripts/review-wispr-teacher.sh
```

The browser opens the 400-item audit queue. For every segment:

1. Listen to the audio before opening the edited Wispr reference.
2. Choose **Accept raw** when the raw transcript is verbatim and correct.
3. Correct the transcript, then choose **Save correction** when it is wrong.
4. Choose **Skip** when the audio is ambiguous or unusable.

Progress is saved after every decision in:

```text
/Volumes/0_Oueillez/wispr-data/review/teacher-audit-400/review-state.json
```

Stopping the server with `Control-C` is safe. Running the launcher again resumes at
the first unreviewed item. The training-ready rows and summary are regenerated at:

```text
/Volumes/0_Oueillez/wispr-data/review/teacher-audit-400/reviewed.jsonl
/Volumes/0_Oueillez/wispr-data/review/teacher-audit-400/review-summary.json
```

Only accepted and corrected items enter `reviewed.jsonl`; skipped items remain
excluded. Training must not start until all 400 decisions have been reviewed and
the skipped items have been replaced or explicitly accepted as exclusions.
