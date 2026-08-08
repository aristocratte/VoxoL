# Parakeet learning-rate sweep

## Why

The promoted recipe trains the top four encoder layers at `3e-6` with an eight-step
warmup over roughly one epoch. The 2026-08-02 candidate decision found that three
decoder implementation defects, not the corpus, explained most of the prior WER gap.
A fine-tune that barely moves its weights produces exactly that signature, so the
learning rate is the first thing to measure before spending a full step budget on the
new mass corpus.

## What it measures

Each probe trains a short budget and is scored on two signals only:

| Signal | Question it answers |
| --- | --- |
| Wispr held-out split | Does the model move toward the teacher at all? |
| FLEURS FR/EN | Does it forget in the process? |

The full pipeline's five benchmarks are the right shape for a promotion decision and
the wrong shape for choosing a hyper-parameter: they spend most of the wall-clock on
evaluation the sweep does not need. A rate that lowers the Wispr WER while holding
FLEURS is the one worth a full run.

## Running it

The sweep runs **on the pod**, after `VoxoL_GPU_Train.sh` has completed at least one
run. It reuses that run's extracted teacher corpus, mixed training manifest and FLEURS
benchmark rather than preparing them again.

```sh
$SOURCE_ROOT/Scripts/run-parakeet-lr-sweep.sh
```

Defaults probe `3e-6`, `1e-5` and `3e-5` for 200 steps each at an effective batch of
16. Overrides:

```sh
$SOURCE_ROOT/Scripts/run-parakeet-lr-sweep.sh \
  --learning-rates 1e-5,3e-5,1e-4 \
  --max-steps 300 \
  --batch-size 4
```

Results land in `<work-root>/sweeps/learning-rate/sweep-summary.json` with a printed
comparison table. Every stage is resumable: an existing probe delta or scored report
is reused, so an interrupted sweep restarts where it stopped.

## Applying the result

The winning rate feeds the full pipeline through the new overrides:

```sh
python3 Tools/training/run_voxol_wispr_gpu_pipeline.py \
  --learning-rate 1e-5 \
  --minimum-learning-rate 1e-6 \
  ...
```

Defaults are unchanged (`3e-6` / `3e-7`, warmup 8, deterministic), so a run that
passes no override reproduces the promoted recipe exactly.

## Batch shape

The 24 GiB profile runs **one** 30-second clip per micro-batch with sixteen
accumulation steps.

Two clips was tried and rejected on measurement. The reasoning behind it was that
freezing the lower encoder layers frees their activations, leaving room to double the
micro-batch — which is true but irrelevant, because the dominant allocation in RNN-T
training is the loss gradient tensor of shape (batch, time, target, vocab). It scales
linearly with the micro-batch and dwarfs what freezing saves. On a real 24 GiB RTX 4090
on 2026-08-03 the two-clip profile reached step 4 and died:

```
torch.OutOfMemoryError: CUDA out of memory. Tried to allocate 6.01 GiB.
GPU 0 has a total capacity of 23.52 GiB of which 4.11 GiB is free.
  File ".../nemo/collections/asr/parts/numba/rnnt_loss/rnnt_pytorch.py", line 142
    label_grads = torch.zeros_like(label_acts) if label_acts.requires_grad else None
```

The pipeline's OOM fallback caught it and restarted at one clip, so the run completed
with an unchanged effective batch and an unchanged optimizer path — the cost was one
wasted attempt, not the run. Raise the micro-batch only with a larger card or a shorter
`max_duration`.

`--batch-size` alone rescales accumulation to preserve the effective batch; passing
`--accumulate-grad-batches` as well takes both values verbatim. Both remain useful on a
40 GiB card or for deliberate experiments.

## Why the 30-second window stays

The 20-second window considered during review was rejected on measurement. In the
2026-08-03 campaign corpus, chunk durations are p50 19.0 s and p90 29.3 s, and **5,140
of 12,354 chunks (41.6%) run past 20 seconds** — the segmenter frequently fails to
find a silence inside its target window and falls back to the ceiling. A 20-second
`max_duration` would silently drop 41.6% of the corpus. The window stays at 30.1 s.

The same measurement explains the boundary statistics: chunks with
`boundary_complete: true` average 18.7 s, while incomplete ones average 26.2 s with
1,132 of 1,680 pinned at exactly 30 s. `--require-complete-boundary` therefore removes
12.2 hours, and it is correctly scoped to the Qwen polisher path only — truncated audio
is still valid ASR training data because the teacher transcribed exactly that chunk.

## Known limitation

Raising the micro-batch makes padding waste real: the duration distribution is
bimodal, so a batch mixing a 6-second clip with a 30-second clip pads everything to 30
seconds. NeMo's bucketing is currently inert in this configuration
(`is_tarred: False`, `bucketing_batch_size: None`). Duration bucketing via a tarred
dataset is the next throughput step and is not part of this change.
