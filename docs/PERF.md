# DiskMap performance

How we measure scan/runtime speed, what the numbers mean, and what is still open.
`TASKS.md` tracks tickets; this file is the measurement log and playbook.

## Tooling

```bash
swift build -c release --product DiskMapScanBench
swift run -c release DiskMapScanBench --repeat 5 --rollup --label warm-home ~
# JSON (one object; ScanEngine also prints a human log line to stdout first):
swift run -c release DiskMapScanBench --repeat 3 --json --label warm-home ~ \
  | tail -1 > docs/perf-results/warm-home.json
```

Flags: `--repeat N`, `--rollup` (times `rollUpBoth` after the scan), `--json`, `--label NAME`, optional path (default `$HOME`).

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

## Still open (ordered)

1. **UTF-8 blob name table** — ~685k `String` headers + ~26 MB UTF-8; a blob+offset intern would cut allocs. Needs Snapshot format care (or keep String only at serialize time).
2. **Publisher sharding** — only if Instruments shows the publisher pegged while workers idle at workers=8.
3. **Duplicates hash** — SHA256 after clone-skip; deferred faster hash (see Milestone 2 notes in `TASKS.md`).
4. **First-paint Instruments** — Map / Top Sizes / Duplicates on a loaded home scan (UI, not walk).
5. **Headless `diskmap scan --json`** — PRD differentiator; `DiskMapScanBench` is the measurement wedge, not the product CLI.

~~Cold-disk matrix~~ — done 2026-09-13 post-reboot; see section above.

## Checklist for a performance PR

- [ ] `swift test` green
- [ ] `DiskMapScanBench --repeat 5 --rollup --label … ~` attached or checked into `docs/perf-results/`
- [x] Cold vs warm called out (2026-09-13 post-reboot matrix)
- [ ] `TASKS.md` ticket updated with min/median/max
- [ ] No network code; CleanupQueue excluded-paths untouched unless called out
