# Model optimization — 26 July 2026

This note records measurements on the reference M4 16 GB Mac. Candidate artifacts stay under
`.build/model-variants` and cannot enter the downloader manifest without a separately published,
immutable and checksummed release.

## Qwen hot path

The production runtime now uses the unbounded short-prompt KV cache, a 512-token prefill step and
one immutable prefix cache per processing language. The cache covers 160 French or 118 English
chat-template/system tokens and is copied before each generation.

On the installed `mlx-community/Qwen3.5-0.8B-4bit` artifact and the 12-case golden suite:

| Configuration | Mean | p50 | p95 | Prompt mean | Golden result |
| --- | ---: | ---: | ---: | ---: | --- |
| No prefix cache | 476 ms | 484 ms | 675 ms | 253 ms | 8 accepted, 2 exact, 3 pipeline exact |
| Prefix cache | 312 ms | 309 ms | 501 ms | 88 ms | 8 accepted, 2 exact, 3 pipeline exact |

The final texts are byte-for-byte identical. Warm-up rose from 1,867 to 2,148 ms, but it runs in
the existing background preparation path. Generation time itself stayed at 213 ms; further gains
now require fewer output tokens or different weights rather than more prompt plumbing.

The old 101-item Wispr teacher suite remains useful only for regression. With the 4-bit model and
prefix cache, the final validated text improved zero items over the deterministic fallback and
regressed one. The generic model therefore remains bypassed whenever the deterministic classifier
does not predict a useful edit.

## Artifact experiments

- Removing 153 unused vision tensors produced a 424 MB text-only artifact from the 615 MB source
  artifact, a 31% disk reduction, with identical golden outputs. Runtime memory did not materially
  change because MLX already avoids retaining the vision tower. Promotion requires publishing this
  derived artifact with immutable URLs, checksums and Apache-2.0 notices.
- A 334 MB affine 3-bit conversion retained only 3/12 accepted golden outputs and emitted malformed
  thinking/content, so it is rejected.
- A 401 MB MXFP4 conversion was faster on the small golden suite, but on 101 private cases it was
  better than affine 4-bit 3 times, worse 5 times and tied 93 times. It also increased accepted
  rewrites without improving the reference metric, so it is rejected.
- The shorter cleanup prompt reduced prompt work but introduced an extra French hallucination.
  Prompt version `voxol-cleanup-v5` remains frozen.

## Parakeet profile

On a short synthetic French utterance, hot end-to-end inference was 97–100 ms. Log-mel extraction
took roughly 1–2 ms, Swift TDT decoding 10–12 ms and the Core ML encoder 85–87 ms. There is no
meaningful Swift hot-path refactor left at this grain; future ASR speed work must target the
encoder artifact, Core ML compute placement or streaming reuse and must preserve parity.

## Public FR/EN smoke baseline

`Scripts/run-public-asr-lite.sh` freezes 50 distinct FLEURS development sentences per language.
Revision `70bb2e84b976b7e960aa89f1c648e09c59f894dd` produced manifest digest
`06f390df45f20afcbf1df716052872ec6fcf69b6ca8bb0625d999ac42acaa796`.

| Slice | Items | Macro WER | Micro WER | Exact match |
| --- | ---: | ---: | ---: | ---: |
| French | 50 | 5.85% | 5.59% | 38% |
| English | 50 | 6.10% | 6.20% | 44% |
| Combined | 100 | 5.98% | 5.87% | 41% |

Hot inference latency was 118 ms p50, 154 ms p95 and 180 ms p99. FLEURS is read speech, so this
smoke can reject bilingual ASR regressions but cannot promote cleanup quality, long-form behavior,
code dictation or robustness to real product microphones.
