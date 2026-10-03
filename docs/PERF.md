# DiskMap performance

How we measure scan/runtime speed, what the numbers mean, and what is still open.
`TASKS.md` tracks tickets; this file is the measurement log and playbook.

## Tooling

```bash
swift build -c release --product DiskMapScanBench
swift run -c release DiskMapScanBench --repeat 5 --rollup --label warm-home ~
# JSON (one object on stdout; ScanEngine's log line goes to stderr since
# 2026-09-28, so no `tail` is needed):
swift run -c release DiskMapScanBench --repeat 3 --json --label warm-home ~ \
  > docs/perf-results/warm-home.json
```

Flags: `--repeat N`, `--rollup` (times `rollUpBoth` after the scan), `--layout` (ChartLayout/treemap/TopSizes/AgeMap after rollup), `--json`, `--label NAME`, optional path (default `$HOME`).

Optional env overrides (A/B only):

| Env | Default | Meaning |
|---|---|---|
| `DISKMAP_SCAN_WORKERS` | `min(CPU, 8)` | Parallel `getattrlistbulk` workers |
| `DISKMAP_SCAN_BUFFER_MB` | `4` | Per-worker bulk attribute buffer |

Raw captured runs from 2026-09-14 live under `docs/perf-results/`.

## Cold vs warm

- **Warm:** path recently read; page cache hot. Most interactive use looks like this.
- **Cold:** after reboot or `sudo purge` (needs admin). DiskBuddy’s “~10s” claims are meaningless without saying which.

Record which one you ran. The matrices below are **warm** unless noted.

## Results — 2026-09-14 (MacBook Air, ~1.80M home items)

Machine: `AYUSHs-MacBook-Air.local`, user home scan, release `DiskMapScanBench`.
Item counts ~1,796,700; not-downloaded = 17. Variance across runs is real — always report min / median / max.

### Warm home after UTF-8 path jobs + publisher pipeline

Label `warm-home-utf8path`, `--repeat 5 --rollup`:

| | scan s | rollup s | walk-peak RSS |
|---|---|---|---|
| min | 9.577 | 0.028 | — |
| median | 10.533 | 0.029 | ~299 MB |
| max | 10.818 | 0.030 | — |

Rollup (`rollUpBoth`) is ~30 ms — not a UI bottleneck after a home scan. ContentView already caches both logical and allocated totals; it now fills them with one tree walk.

### Worker A/B (warm, 3 repeats each)

| Workers | min | median | max |
|---|---|---|---|
| 4 | 8.722 | **8.861** | 8.967 |
| 8 | 5.949 | **6.038** | 6.044 |
| 12 | 9.512 | **9.911** | 10.749 |

**Decision:** default workers = `min(CPU, 8)`. Twelve workers regressed (publisher / lock / cache contention). Eight was both fastest and tightest.

### Buffer A/B (warm, 3 repeats each)

| Buffer | min | median | max |
|---|---|---|---|
| 1 MB | 5.905 | 9.682 | 10.509 |
| 4 MB | 5.830 | **6.166** | 9.182 |

**Decision:** default buffer = 4 MB. Median improves; still noisy at the tails.

### Confirm after default change (workers=8, buffer=4 MB)

Label `confirm-defaults-v2`, 3 warm repeats:

| | scan s |
|---|---|
| min | 5.882 |
| median | **5.940** |
| max | 8.950 |

Raw: `docs/perf-results/confirm-defaults-v2.txt`.

### Cold vs warm after reboot (2026-09-13 evening)

Machine restarted, then immediate `--repeat 5 --rollup` home scans (~1.75M items, ~1.72M nodes, ~681.5k unique names, ~26.3 MB name UTF-8).

**Cold** (`cold-home-post-restart`, raw `docs/perf-results/cold-home-post-restart.txt`):

| | scan s | rollup s | walk-peak RSS (median) |
|---|---|---|---|
| min | 5.878 | 0.021 | — |
| median | **10.506** | 0.030 | ~365 MB |
| max | 11.866 | 0.032 | — |

Run order: 11.866 → 11.116 → 9.612 → 10.506 → 5.878 (last run already warming).

**Warm** (`warm-home-post-restart`, raw `docs/perf-results/warm-home-post-restart.txt`):

| | scan s | rollup s | walk-peak RSS (median) |
|---|---|---|---|
| min | 8.500 | 0.029 | — |
| median | **9.855** | 0.031 | ~346 MB |
| max | 10.190 | 0.033 | — |

**Notes:** Cold first-hit is ~12 s; once the page cache is hot, wall time lands in the same noisy band as other warm matrices. This warm median (9.9 s) is slower than `confirm-defaults-v2` (median 5.94 s) — treat that gap as session noise (thermal / FS churn / other load), not a regression ticket. Always report min/median/max for a given session.

### Earlier control (pre–UTF-8-path, publisher + 2M reserve)

Back-to-back originals spanned ~6.4–9.9 s. Best documented baseline before this pass: 7.312 s (2026-09-14 getattrlistbulk note in `TASKS.md`). Best after capacity prep: 6.035 s. Best after worker=8 A/B: **5.949 s**.

### Synthetic / volume tests

`swift test` (42 tests) includes:

- `SyntheticScanStressTests.bushyTreeScanCompletesWithExpectedNodeCount` — 40×25 file tree, expects ≥1041 nodes.
- `ExternalVolumeScanTests.mountedVolumeScanDoesNotHangWhenPresent` — scans first non-`Macintosh HD` entry under `/Volumes` if any; skips cleanly otherwise.

## What we tried and rejected

- **`openat` fd handoff for children** — wall time ~10 s flat; reverted. Path UTF-8 buffers are the lighter approach.
- **Default max 12 workers** — A/B shows 12 is slower than 8 on this machine.

### Packed UTF-8 name blob (Phase 1, 2026-09-13)

`FileTree` stores unique names in `nameBlob` + `nameOffset`/`nameLength` instead of `[String]`.
Scan-hot intern hits still compare raw UTF-8 (via `memcmp`); `String` is built only for UI/`name(of:)`.

Warm home `--repeat 5 --rollup --label warm-home-utf8blob` (~1.77M items):

| | scan s | rollup s | walk-peak RSS (median) |
|---|---|---|---|
| min | 5.874 | 0.022 | — |
| median | **9.859** | 0.038 | ~321 MB |
| max | 10.770 | 0.039 | — |

Footprint: `nameTableHeaderBytes` is now offset+length table (~**4.1 MB** for ~684k names) vs former `MemoryLayout<String>` × N (~**10.9 MB**). `name_utf8` stays ~26.3 MB.
Raw: `docs/perf-results/warm-home-utf8blob.txt`. Snapshot encode still emits length-prefixed strings (v1 format unchanged).

### Publisher sharding gate (Phase 2)

Full Xcode / `xctrace` is **not** installed (only Command Line Tools). Used `/usr/bin/sample` for 8s during a release home scan (`docs/perf-results/publisher-sample.txt`).

**Decision: no publisher sharding.** Sample captured no evidence of a pegged publisher with idle workers; call graph was effectively empty (I/O-bound / wait). Keep single publisher at workers=8.

### Faster duplicates hash (Phase 3)

- Partial (64 KB) filter: `Insecure.MD5` (collisions still rechecked).
- Full content: streaming `SHA256` in 1 MB `FileHandle` chunks (nil-at-EOF is success).
- Dup tests green (42 suite). Peak-memory win on large files; wall time is I/O bound for typical cache-sized files.

### UI first-paint stand-in (Phase 4)

No Instruments (no Xcode). Added `DiskMapScanBench --layout`: after rollup, times `ChartLayout.slices` + `SquarifiedTreemap.layout` + `TopSizes.ranked` + `AgeMap.bucketSizes`/`untouched` on the home tree.

`warm-home-layout`: layout=**0.091 s** (91 ms) — under the ~100 ms hitch bar, so **no code fix**. Raw: `docs/perf-results/warm-home-layout.txt`. Re-run with Instruments Time Profiler when Xcode is installed for true SwiftUI first-paint.

## Still open (ordered)

1. **Headless `diskmap scan --json`** — PRD differentiator; `DiskMapScanBench` is the measurement wedge, not the product CLI.
2. **True SwiftUI Instruments first-paint** — install full Xcode and re-check Map / Duplicates / Age Map; layout stand-in is already <100 ms.

~~Cold-disk matrix~~ — done 2026-09-13 post-reboot.
~~UTF-8 blob name table~~ — done (packed blob + offsets).
~~Publisher sharding~~ — no-go without pegged publisher evidence (`sample`).
~~Duplicates hash~~ — MD5 partial + streaming SHA256.
~~First-paint layout stand-in~~ — 91 ms; no fix.


## Checklist for a performance PR

- [ ] `swift test` green
- [ ] `DiskMapScanBench --repeat 5 --rollup --label … ~` attached or checked into `docs/perf-results/`
- [x] Cold vs warm called out (2026-09-13 post-reboot matrix)
- [ ] `TASKS.md` ticket updated with min/median/max
- [ ] No network code; CleanupQueue excluded-paths untouched unless called out

### DuplicateFinder RSS — Downloads (TASK-028, 2026-09-14)

`DiskMapScanBench --duplicates ~/Downloads`:

| metric | value |
|---|---|
| scan items | 23 724 |
| candidates | 20 080 |
| groups | 281 |
| full_hash_calls | 748 |
| dup elapsed | 0.331 s |
| rss_before | 75 907 072 (~72.4 MB) |
| rss_peak_sampled | 146 751 488 (~140.0 MB) |
| rss_after | 146 751 488 (~140.0 MB) |

Raw: `docs/perf-results/downloads-duplicates-rss.txt`. No concurrency
cap added — peak stayed modest on this folder.


## Scan identity + hard-link rollups (TASK-036 / TASK-037, 2026-09-25)

### Attribute-mask A/B — does file identity cost anything?

Adding `ATTR_CMN_DEVID`, `ATTR_CMN_FILEID`, `ATTR_FILE_LINKCOUNT` and
`ATTR_DIR_LINKCOUNT` grows each `getattrlistbulk` record by 16 bytes
(`fixedPrefix` 92 → 108) and adds an 8 B/node `[UInt64]` to `FileTree`
(`packedNodeStride` 42 → 50).

The home tree has grown to ~2.05M items since the 2026-09-14 matrices, so the
historical 1.79M numbers are **not** a valid control. Measured instead against
the pre-change commit (8190439) in a throwaway worktree, same machine, same
tree, same session, 5 warm repeats each:

| | baseline (pre-036) | with identity | delta |
|---|---|---|---|
| scan min | 6.916 s | 6.847 s | −1.0% |
| scan **median** | **6.932 s** | **6.993 s** | **+0.9%** |
| scan max | 9.598 s | 12.794 s | (tail; see below) |
| walk RSS median | 411.6 MB | 413.0 MB | +1.4 MB |
| items | 2 054 730 | 2 054 729 | same tree |

**Decision: ship it.** A +0.9% median is inside the documented noise band, and
the minimum improved. Zero extra syscalls — the same bulk call returns a wider
record. Both `max` values are the first run of their series and the spread
(6.8–12.8 s) is the same tail already documented under "Cold vs warm"; it is
not a signal about this change. Per-item cost: 3.37 µs baseline vs 3.40 µs.

Raw: `docs/perf-results/task036-identity.txt`, `baseline-pre036.txt`.

### What hard-link de-duplication actually corrected

`DiskMapScanBench --rollup` now prints a `hardlinks` line. Warm home,
3 repeats, identical across runs:

| metric | value |
|---|---|
| flagged nodes (`ATTR_FILE_LINKCOUNT > 1`) | 14 953 |
| inodes with >1 name inside the tree | 4 525 |
| duplicate names charged 0 | 10 428 |
| **allocated bytes no longer double-counted** | **766 058 496 (~730 MiB)** |
| logical bytes no longer double-counted | 745 790 079 |
| cross-mount skips (home scan) | 0 |

**This is the headline: the home scan was over-reporting by ~730 MiB.** Not a
synthetic edge case — 4 525 real inodes, mostly framework and toolchain trees
that ship hard-linked payloads.

### Rollup cost of the correction

`rollUpBoth` went from ~0.028 s to ~0.042–0.053 s on the same tree: one extra
linear pass over the `flags` byte array, plus path construction for the 0.7%
of nodes that are flagged (election must be path-based for stability — see the
decision log). Still an order of magnitude under the ~100 ms first-paint bar,
and it buys a 730 MiB correctness fix. Trees with no hard links return `nil`
from the mask builder and allocate nothing.

Raw: `docs/perf-results/task037-hardlinks.txt`.

## Measuring staged folders (TASK-038, 2026-09-28)

`DiskMapScanBench --profile PATH` times `StorageSharing.profile`, i.e. what
staging a folder costs. Warm, release, 3 repeats:

| path | files | seconds | notes |
|---|---|---|---|
| `~/Library/Caches` | 325 289 | 9.56–10.22 | incomplete (unreadable dirs without FDA) |
| `~/Library` | 719 346 | 26.6–46.2 | first run cold |

Single-threaded, ~35–50k entries/s. This is why staging measures in the
background and disables Move to Trash until done. A parallel walk (the scan
does 2.25M items in ~8 s with 8 workers) is the obvious follow-up; not done.

### Trust-pass scan A/B, interleaved (2026-09-28, ~2.25M items)

Pre-trust-pass commit 8190439 vs current, alternating runs so session drift
hits both equally, 6 pairs:

| | min | median | mean | max |
|---|---|---|---|---|
| base | 8.010 | 8.756 | 9.464 | 11.860 |
| current | 7.715 | 9.251 | 9.333 | 11.574 |

Paired differences ranged −3.96 s to +2.74 s (median −0.10 s). No detectable
regression; run-to-run variance on this machine is now larger than any effect
of the trust pass.

## Post-walk phases (TASK-042, 2026-09-28)

`DiskMapScanBench --phases` times every step between "walk finished" and "UI
can paint", in the order `ContentView.scan` runs them. Warm home, ~2.25M
items, release, 5 repeats (min / median / max, seconds):

| phase | min | median | max |
|---|---|---|---|
| walk | 7.686 | 8.363 | 10.303 |
| rollUpBoth | 0.043 | 0.049 | 0.054 |
| rollUpDescendantCounts | 0.015 | 0.017 | 0.019 |
| QuickWins | 0.065 | 0.068 | 0.266 |
| FileTypes | 0.604 | 0.614 | 0.636 |
| AnalysisSnapshot | 0.322 | 0.329 | 0.505 |
| ForgottenFiles | 0.109 | 0.113 | 0.116 |
| ReviewableCatalog | 0.053 | 0.055 | 0.076 |
| DeveloperCatalog | 0.827 | 0.930 | 0.985 |
| **OldDownloadsCatalog** | 2.790 | **2.835** | 3.020 |
| **MediaCatalog** | 3.733 | **3.792** | 3.858 |
| layout | 0.000 | 0.000 | 0.000 |
| **post-walk total** | 8.826 | **8.875** | 8.977 |

**The post-walk pipeline takes longer than the walk.** Every earlier number in
this file measured only the walk (and rollup, and layout), so the ~9 s a user
actually waits after it — frozen on "Almost there…" — was invisible. The
roadmap guessed "a second hiding in plain sight"; it is nine.

Two catalogs are 6.6 s of it, and each backs exactly one screen. Decision for
Milestone 9: build only what first paint needs (rollups, QuickWins, FileTypes,
AnalysisSnapshot ≈ 1.1 s) eagerly; everything else on first visit (TASK-043).
MediaCatalog and OldDownloadsCatalog are also slow in themselves — a user
opening those screens would still wait seconds — so their cost gets its own
look. Raw: `docs/perf-results/task042-phases.txt`.

### Catalog speed-ups, proven output-identical (TASK-069, 2026-09-28)

Three of the slow phases were building a full path (`tree.path(of:root:)`,
one URL component at a time) for nearly every node, only to substring-test it
or throw it away:

- **OldDownloadsCatalog** built a path for every file over 1 MB on the disk to
  test for `/downloads`. A needle starting with `/` can only match at a
  component boundary, so it is exactly "some component starts with
  *downloads*" — now `FileTree.folderChainFlags`, one forward pass over folder
  names (`parent[i] < i`), paths built only for files that pass.
- **MediaCatalog** did the same for its one path-dependent rule (`/final cut`),
  then built full candidates (path, safety, display strings) for every media
  file although only the largest 2 000 were kept. Now: name-only matching,
  sort light tuples (ties by node id, as the stable sort did), build candidates
  until 2 000 survive.
- **FileTypes** re-derived the extension and scanned the category list for all
  ~2.2M files; names are interned (~900k distinct), so each distinct name is
  resolved once, through an extension→category dictionary.

**Equivalence was checked, not argued.** A real home scan was frozen
(`--save-snapshot`); `--catalog-dump` wrote every UI-visible field of both
catalogs plus the file-type totals from that exact tree before and after; the
two 2 413-line dumps are byte-identical.

| phase (live home, median of 3) | before | after |
|---|---|---|
| MediaCatalog | 3.792 | 0.519 |
| OldDownloadsCatalog | 2.835 | 0.098 |
| FileTypes | 0.614 | 0.217 |
| **post-walk total** | **8.875** | **2.524** |

DeveloperCatalog (0.87 s) is now the largest remaining phase; it is rebuilt in
Milestone 11 and made lazy in TASK-043.

## Walk micro-waste: measured, not changed (TASK-045, 2026-09-28)

The roadmap listed four suspected costs on the publisher thread. One (a
throwaway path `String` per directory) was removed in TASK-036. The other three
were instrumented on a real 2.25M-item home scan before touching code that has
already had two concurrency bugs:

| suspect | measured |
|---|---|
| `broadcast()` where `signal()` might do | 526 110 broadcasts, but workers woke only **143** times (100 spurious) — they almost never wait. Publisher woke 164 153 times, only **72** spurious. |
| `task_info` every 4 000 items | **2 ms** per scan |
| zero-filling 8 × 4 MB worker buffers | **5 ms** per scan |

**Decision: no change.** Under 10 ms of an 8–11 s scan, and switching to
`signal()` would add lost-wakeup risk to the scheduler for nothing.

## p95 is tracked (TASK-046, 2026-09-28)

`DiskMapScanBench` now prints `scan_p95` (nearest rank). Baseline, warm home,
2.25M items, 20 runs (`docs/perf-results/p95-baseline.txt`):

| min | median | p95 | max |
|---|---|---|---|
| 7.751 | 8.012 | **10.743** | 11.569 |

Fourteen runs fall in 7.75–8.55 s; four form a 9.5–11.6 s tail. The probe
above rules out the publisher as the source (72 spurious wakeups per scan), so
the tail looks external — disk contention, Spotlight, thermals. **Goal: p95 ≤
1.25 × median** (today 1.34 ×). Report `scan_p95` with n ≥ 20 on any walk change.

## Exports (TASK-058, 2026-09-28)

`diskmap export ~ --format F --out FILE`, release, warm, 2.25M items, 3 runs
each (`docs/perf-results/cli-export-home.txt`). Wall time includes the walk;
`diskmap scan ~ --json` alone: 8.59 / 11.03 / 10.17 s.

| format | min | median | max | output |
|---|---|---|---|---|
| json   | 11.69 | 12.70 | 12.91 | 240 MB |
| ncdu   | 12.22 | 13.16 | 15.80 | 176 MB |
| csv    | 12.06 | 16.15 | 16.83 | 325 MB |
| ndjson | 14.23 | 16.61 | 17.72 | 468 MB |

Writing costs roughly 2.5–6.5 s on top of the walk, tracking output size. The
app's Export Scan… reuses the in-memory tree, so it pays only the writing.
Before the day-string cache and JSON fast path, NDJSON writing alone took ~18 s.

## Find queries (TASK-059, 2026-09-29)

`DiskMapScanBench --from-snapshot SNAP --repeat 7 --query "…"` on the frozen
real home (2.25M nodes, ~685k distinct names), release. Recorded while the
machine was swapping heavily (19 GB swap), so treat as upper bounds;
`docs/perf-results/find-query-home.txt` has every run.

| query | before | after |
|---|---|---|
| `ext:mp4,mov size>100MB` | 5.9 ms | — |
| `in:downloads age>180d` | 26.9 ms | — |
| `name:*.log -xcode` | 765 ms | 72.5 ms |
| `kind:archive in:library` | 247 ms | 77.1 ms |
| `type:any readme` | 274 ms | 60.9 ms |
| `café` | 1 271 ms | 32.0 ms |
| `type:any a` (1.39M matches) | 138 ms | — |

What moved it: per-name tests on raw UTF-8 with a reused scratch buffer (no
String per distinct name), a definite "no" for ASCII names against non-ASCII
words, and a literal-substring prefilter before `fnmatch`. The worst case
seen is a glob whose only literal is one letter (`name:*e?d*`, 327 ms).

## Quick rescans (TASK-061, 2026-09-29)

`DiskMapScanBench --incremental 7 ~` (release; machine swapping ~19 GB):
full walk 8.017 s for 2 259 179 items, then quick updates from the tree in
memory — as the app's Rescan does:

| | min | median | max |
|---|---|---|---|
| quick update | 0.210 s | 0.247 s | 0.797 s |

The first update is the slow one: it absorbs changes made during the walk.
From the disk cache (relaunch, `diskmap … --incremental`) an update is
~0.75 s: 0.45 s reading the cached tree, 0.19 s copying 2.25M nodes, ~0.1 s
of spot checks, 28 ms for the event barrier and replay. Wall time for
`diskmap check ~ --incremental` is 1.45–1.97 s against 9.3 s for a walk
(`docs/perf-results/incremental-home.txt`).


## Clone accounting (TASK-077, 2026-10-03)

`DISKMAP_SCAN_SHARING=off|refcount|full DiskMapScanBench ~` (release, ~2.58M
items, modes alternated, 8 rounds on an otherwise idle machine —
`docs/perf-results/clone-scan-ab.txt`):

| walk | min | median | p95 | max |
|---|---|---|---|---|
| off | 13.76 s | 16.97 s | 20.42 s | 21.04 s |
| refcount (CLONEID + REFCNT) | 16.03 s | 19.78 s | 24.98 s | 25.77 s |
| full (+ PRIVATESIZE) | 27.32 s | 31.47 s | 38.18 s | 40.13 s |

Paired per round, refcount costs +14% at the median (p95 of totals +22%) and
full ~1.9×: over the 10% budget, so clone accounting is a setting, off by
default. With it on, `rollUpBoth` goes from 0.06 s to 0.13–0.17 s (a sort of
884k clone rows; dictionaries took 0.8 s) and AnalysisSnapshot +0.04 s. The
side table is 24 bytes per clone row — 884k rows, ~21 MB, on this home.

What it changes: `diskmap scan ~` reports 353.45 GB without it and 270.36 GB
with it (83.09 GB in 715,110 cloned copies counted once; ~/Library 152.19 →
85.3 GB).

## Walk-time tail (TASK-086, 2026-10-03)

Goal was p95 ≤ 1.25 × median. A sequential 20-run home walk gave median
15.52 s, p95 24.06 s (1.55×), slow runs clustered together. Suspect: the
walk reserves 1M nodes / 400k names, but the home has 2.68M nodes and 950k
names, so the arrays and the intern table regrow mid-walk. Tested reserving
from the last scan's counts × 1.1, in 12 alternating pairs: the hinted walk
was **not faster** (paired median 1.07×, range 0.78–1.47×; p95 17.67 s plain
vs 20.20 s hinted). Regrowth costs tens of milliseconds, not seconds. Load
average was 6.5–10 throughout and a Docker VM swung between idle and 100% CPU
from run to run — the tail follows outside load. Not shipped; evidence in
`docs/perf-results/p95-walk-tail.txt`. Measure walk variance only on a quiet
machine (no VM), alternating A/B, never sequential blocks.
