# Wispr teacher replay training

The v2 challenger uses the frozen Wispr raw corpus as the product teacher target
and FLEURS train/dev as a 50% item-level replay set. The package contains 16.22
hours of train, 3.39 hours of validation and 3.97 hours of test audio. Every
recording from v1 keeps its original split, and the 20 new recordings are assigned
without source or speaker overlap.

The recipe is fixed:

- train encoder blocks 20–23 only;
- freeze predictor, joint and every BatchNorm parameter/statistic;
- learning rate `3e-6`, minimum `3e-7`, warm-up 8 steps;
- stop after 145 optimizer steps;
- validate and save every 18 optimizer steps;
- deterministic seed 1337;
- select the checkpoint with global normalized WER over the mixed validation set.

After a RunPod TCP SSH endpoint is available, launch and monitor everything from
the Mac with:

```bash
/Users/aris/Documents/Zphyr/Scripts/launch-voxol-runpod-training.sh HOST PORT root
```

The script defaults to `voxol-wispr-asr-v2-20260801.tar.gz`, verifies and reuses remote uploads, starts training independently of
the SSH connection, reports elapsed cost, retrieves the final ZIP and verifies
its integrity. It does not stop RunPod billing; the Pod must still be stopped or
destroyed after the archive is recovered. All inputs, caches, checkpoints and
exports are stored below RunPod's persistent `/workspace` volume. NeMo, the Python
environment and downloaded model caches also live under `/workspace`, so a Pod
migration or a launcher restart reuses them instead of repeating the long setup.

Keep the external SSD connected until the 2.1 GiB teacher archive has finished
uploading. If the local terminal or network disconnects after training starts,
run the same command again: the verified dataset, runtime, checkpoints and remote
process are reused. The monitor reports installation stages before the Python
pipeline has created its detailed training status.

A candidate is rejected unless all of these conditions pass:

- stored checkpoint-selection WER exactly matches an external re-score;
- Wispr teacher WER improves globally and in French and English;
- empty Wispr outputs do not increase;
- FLEURS overall, French and English regress by at most 0.5 WER point;
- MediaSpeech regresses by at most 0.5 WER point and empty outputs do not increase.

Passing this source gate authorizes Core ML parity and latency measurement. The
candidate must then beat the current production model on the frozen v2 test:
overall WER at most 7.81%, French at most 10.23%, English at most 5.56%, with no
additional empty output. It does not authorize automatic production replacement.
