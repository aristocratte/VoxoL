# Campaign completion estimate

`Scripts/campaign-eta.py` answers one question: when will the Wispr transcription
campaign finish?

```sh
./Scripts/campaign-eta.py              # one measurement
./Scripts/campaign-eta.py --watch 60   # refresh every minute
./Scripts/campaign-eta.py --json       # machine-readable
```

`Ctrl+C` stops the display only. The tool never writes anything except its own sample
log at `<campaign-root>/logs/eta-samples.jsonl`.

## Why the obvious estimate is wrong

Counting finished recordings and dividing by elapsed time overestimates progress
badly on this campaign, because a resumed run **re-walks** recordings it already
collected. Those finish in seconds — every chunk is reused rather than fetched — so
the recording rate during a re-walk is many times the rate of genuine collection.

The 2026-08-03 17:33 run illustrates it: 19 chunks genuinely collected against 5,042
reused. A naive estimate taken during that phase reads a throughput that will not hold
once the workers reach the sources that still need fetching.

File modification times do not rescue the estimate: re-walking rewrites both the chunk
audio and the chunk result files, so on-disk timestamps no longer reconstruct when the
data was actually collected.

## What the tool measures instead

**Remaining work is exact, not estimated.** `corpus/manifest.jsonl` lists every planned
source with its duration, and a source is finished when its `record.json` exists. The
remainder is the difference — sources, audio hours, and chunks at the observed mean
chunk length.

**Throughput is measured differentially.** The run log is append-only, and a line
matching `chunk N/M collected` means a chunk actually went to the API, while `reused`
means it did not. The tool samples that counter, persists each sample, and derives the
rate from the difference between samples inside a trailing window.

Consequences worth knowing:

- The first invocation cannot produce a rate. It stores a sample and says so.
- A re-walk still trickles a few genuine collections, so its measured rate is small but
  rarely exactly zero — and projecting that trickle onto 1,361 remaining chunks yields a
  confident, badly wrong answer (a measured 0.9 chunks/min once produced "24 h 36 min"
  while the real fresh work had not started). The tool therefore also tracks the
  **share** of chunks in the window that were genuinely collected, and withholds the ETA
  below `FRESH_SHARE_FOR_ETA` (20%). It prints the rate and says why it will not project
  it.
- A rotated log restarts its counter. Samples carry the log's device/inode identity and
  pairs that straddle a rotation are skipped rather than read as negative progress.
- When the live window cannot support a projection, the tool falls back on the
  **sustained rate of finished runs**. A completed log is a clean measurement: its name
  carries the start time, its last write marks the end, and its `collected` count is
  genuine fetching. The 04:05 run collected 12,399 chunks in 13 h 27 min — 15.4
  chunks/min — and that is what the remaining sources will be fetched at. Runs dominated
  by reuse, or too small to mean anything, are excluded from the average.

The ETA covers **fetching only**. Time spent re-walking already-collected recordings
before the workers reach the outstanding sources is additional, and the report says so.

The report also prints a floor: the time the remaining chunks would take at the
collector's minimum request spacing (`WISPR_MIN_REQUEST_INTERVAL`, two requests per
chunk). Real throughput is always slower — the floor bounds the optimistic side.

## Reading the report

```
  Sources    122/148 terminées   (26 restantes)
  Audio      67.79 h collectées   |   7.47 h restantes
  Chunks     12354 collectés   |   ~1361 restants (à 19.8 s/chunk)
  Workers    4 actifs
  Phase      re-parcours (chunks déjà collectés) — 19 collectés / 5042 réutilisés
```

`Phase` is the line to read first. While it says *re-parcours*, the ETA is pending by
design; once it flips to *collecte fraîche*, two samples a minute apart give a real
number.
