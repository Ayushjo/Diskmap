# TASKS

Work top to bottom. One ticket per Cursor session where practical — small,
reviewable diffs beat one giant "build the app" prompt. Each ticket has a
goal, acceptance criteria, and a prompt you can paste into Cursor as-is
(edit if you want, but it's meant to be usable directly).

Check items off as you go — this file is the actual source of truth for
project status, more than any conversation history.

## Milestone 1 — Prove the core

- [x] **TASK-001: Verify and fix SquarifiedTreemap**
  Acceptance: `swift test --filter SquarifiedTreemapTests` passes; manual
  render against a real folder shows no visible gaps/overlaps.
  Prompt: *"Run `swift test --filter SquarifiedTreemapTests`. If it fails,
  debug `SquarifiedTreemap.swift`'s `squarify()` against the reference
  example in Bruls/Huizing/van Wijk (2000), Figure 6 — sizes
  [6,6,4,3,2,2,1] in a 6x4 rect — until tests pass. Follow the guidance in
  `.cursor/rules/020-verify-unverified-code.mdc`."*

- [x] **TASK-002: Verify ScanEngine against a real large folder**
  Acceptance: scanning your home directory completes without hanging,
  memory stays reasonable (check Activity Monitor), `scannedCount`
  updates live in the UI.
  Prompt: *"Run DiskMapApp, scan my home folder, and report scan time and
  peak memory from Activity Monitor. If it hangs or crashes, find and fix
  the bug in ScanEngine.swift — likely candidates are the `enumerator.level`
  stack-popping logic or a resourceValues call throwing on a permission-
  denied file."*

- [x] **TASK-002b: Release RSS split and checked-in iCloud snapshot**
  Acceptance: release scan reports walk-peak RSS and post-`scan()` RSS
  separately; packed-array bytes from `MemoryLayout` are compared to the
  post-scan number; iCloud decision test replays
  `Tests/Fixtures/evicted-ubiquitous-item.json`.

- [x] **TASK-002c: Drain walk autoreleases and compact FileTree**
  Last memory-measurement ticket. Release home scan, 2026-09-13, after
  `autoreleasepool` every 4000 items and `FileTree.compact()` at the end
  of `scan()`: 1,653,975 items, 1,640,384 nodes, 373.357 s, 17
  not-downloaded. Hypothesis held (walk peak especially). Do not re-test.

  | | Walk peak | After `scan()` |
  |---|---|---|
  | Before (TASK-002b) | 5,016,731,648 | 865,779,712 |
  | After (pool of 4000 + compact) | 417,415,168 | 473,972,736 |

  Compact did not reach `capacity == count`: reserved 74,432,224 vs
  exact 62,334,592 (12.1 MB of allocator rounding, down from 55.2 MB of
  doubling slack). Steady-state dropped 392 MB, more than compact alone,
  so the pool also stopped walk objects from leaving pages mapped after
  `scan()` returned.

- [x] **TASK-003: Tap-to-drill-down + breadcrumb**
  Acceptance: clicking a treemap rectangle navigates into that folder;
  a breadcrumb bar lets you navigate back to any ancestor.
  Prompt: *"In ContentView.swift, implement the TODO in
  TreemapContainerView's onTapGesture: cache the last-computed
  `[TreemapRect]` in @State, hit-test the tap location against it on
  release, and if it's a directory, set currentNode to that id. Add a
  breadcrumb bar above the canvas built by walking currentNode's parent
  chain, each segment tappable to jump back to that ancestor."*

- [x] **TASK-004: Logical vs. size-on-disk toggle**
  Acceptance: a toggle in the header switches all displayed sizes between
  `logicalSize` and `allocatedSize` totals.
  Done: segmented Logical / On Disk control in the treemap header.
  `FileTree.rollUpSizes(basis:)` fills the array the treemap and the
  breadcrumb size read. Default remains allocated, so older callers stay
  on size-on-disk. A not-downloaded directory with no children contributes
  its own recorded size (descendants were never enumerated).
  Live check, same day, scan of `~/Library/Mobile Documents` (139 items,
  the same 17 not-downloaded files the home scan found, all files, no
  directories): all 17 have allocated size 0. 16 have a positive logical
  size (17,155,756 bytes combined). One has logical 0 as well, so both
  modes show 0 for that file. One parent folder's rolled-up totals are
  2,844 logical and 0 on disk — that is the number the header shows when
  that folder is current, and the number the child's rectangle uses.
  Paths were not recorded.

### Milestone 1 complete

Core scan, treemap, drill-down, and the logical / on-disk toggle are in.
`swift test`: 22 tests, 0 failures (2026-09-13). Nothing else in
Milestone 1 is open.

Deferred, on purpose, before Milestone 2:

- **iCloud `skipDescendants` + `NodeFlags.notDownloaded`** — already
  landed in TASK-002. There is no open TODO for it in `ScanEngine.swift`.
  Do not re-open it as unfinished.
- **`CloneDetector.swift`** — verified in TASK-005. Wired into
  duplicate grouping in TASK-006.
- **`DuplicateFinder` clone-skip** — landed in TASK-006. A full extent
  map skips the content hash. A partial clone does not.
- **SHA256 in `DuplicateFinder`** — stays for Milestone 2. A faster hash
  is a performance follow-up after duplicates ship, not a new ticket and
  not a Milestone 1 gap.
- **Treemap hash-to-hue coloring** — TASK-023 (visual polish). Not a
  layout or size bug.
- **Zero-size rectangles in On Disk mode** — recorded, not implemented.
  `SquarifiedTreemap` drops size ≤ 0, so a cloud-only file disappears
  from the map when the toggle is On Disk, though the breadcrumb still
  reaches its parent and the header shows 0. Decision: leave the filter.
  A fixed minimum-width sliver (the GrandPerspective/WinDirStat
  convention) would draw on-disk-empty items as if they occupied space,
  which is a lie in that mode. Revisit only if the disappear-on-toggle
  confusion shows up in use.

## Milestone 2 — Duplicates + clones

- [x] **TASK-005: Verify CloneDetector against a real header + real clone pair**
  Acceptance: `log2phys` struct and `F_LOG2PHYS` constant confirmed
  against the active SDK; `cp -c a.bin b.bin` pair correctly detected as
  clones; two unrelated same-size files correctly detected as not-clones.
  Done, macOS 15.5 SDK: `F_LOG2PHYS` is 49 (the guess was right).
  `struct log2phys` is `#pragma pack(4)`, 20 bytes, device offset at 12.
  The hand-rolled Swift struct was 24 bytes and read the offset at 16.
  That misread reported 92 for both of two unrelated 8192-byte files
  whose real offsets were 397016842240 and 397018812416. `F_LOG2PHYS_EXT`
  (65) is required: a 4 KB write at offset 1 MB of an 8 MB clone left
  `F_LOG2PHYS` still returning the shared head offset. Full extent maps
  are compared.

- [x] **TASK-006: Wire clone-skip into DuplicateFinder**
  Acceptance: within a partial-hash collision group, any pair confirmed
  as clones by CloneDetector is grouped without a full-content hash call.
  Done: only `areLikelyClones` (full `F_LOG2PHYS_EXT` map) skips
  `fullHash`. Fresh `cp -c` pair: 0 full hashes, `sharesStorage` group.
  Independent copy of the same bytes: 2 full hashes, content group.
  8 MB clone with a 4 KB write at offset 1 MB: 2 full hashes, no group.
  Deleting one copy of a shared group reclaims 0; deleting every copy
  reclaims `sizeEach` once.

- [x] **TASK-007: Duplicates view**
  Acceptance: a new view listing duplicate groups (grouped list, size,
  path per file, select-to-stage into CleanupQueue), reachable from
  ContentView.
  Prompt: *"Build a DuplicatesView.swift in Sources/DiskMapApp: run
  DuplicateFinder against all files under the current scan, display
  results grouped by hash with a checkbox per file (default: all but the
  oldest-modified file in each group pre-checked, matching DiskBuddy's
  keep-one-original behavior), and a 'Stage Selected' button that calls
  CleanupQueue.stage for each checked file."*
  Done: Duplicates page, oldest file stays unchecked, Stage Selected
  goes through `CleanupQueue`. Shared-clone groups say deleting one copy
  does not free space. Queue `totalSize()` is reclaimable bytes: one
  clone of a pair contributes 0; both contribute `sizeEach` once.
  Content duplicates still contribute their own size. Excluded-path
  prefixes were not changed.

## Milestone 3 — Remaining visualizations

Reclaim loop (cleanup queue, Quick Wins, app leftovers) was pulled
forward after TASK-007. Do these views after that loop is usable, in
this order: Top Sizes, Folders, Age Map, then the four layout charts.

Each of these consumes the same `tree.children(of:totals:)` data the
treemap already uses — the work is a new layout function, not new scanning
logic.

Size basis lives on `ScanModel`, so Map, Top Sizes, Folders, Age Map, and
the layout charts share Logical / On Disk and do not rescan. The segmented
page picker was replaced with a sidebar; it was already at 520pt with five
pages.

- [x] **TASK-008: Sunburst view** — polar/radial treemap, rings = depth.
  Done: wedges from the top, clockwise, one extra ring. Children under
  0.5% of the parent collapse into a non-drillable Other.
- [x] **TASK-009: Flame graph view** — icicle layout, depth top-to-bottom.
  Done: full-width bars, left to right by size, next depth underneath.
  Same Other collapse. Click a directory bar to drill.
- [x] **TASK-010: Bubbles view** — circle packing (see D3's pack layout for
  the reference algorithm if SwiftUI-native isn't obvious).
  Done: radii from `sqrt(size)`, each sibling seated tangent to an already
  placed circle, then separated so a missed angle cannot overlap. Tested.
  Not a spiral. Enclosing circle may have empty space.
- [x] **TASK-011: Mind map view** — radial tree, branches from center.
  Done: current node at the center, children on a circle, radius scaled
  by size, labels only when the wedge is wide enough. Same Other collapse.
- [x] **TASK-012: Top Sizes view** — flat ranked list, no layout algorithm
  needed, just sort totals descending.
  Done: non-root nodes, selected totals, capped at 500. Directories use
  subtree totals. No staging. Cloud-only files stay listed and are not opened.
- [x] **TASK-013: Age Map view** — bucket `modifiedDay` into ranges, render
  as a heatmap grid; surface a "Big & Untouched" (>1yr old, large) filtered
  list per DiskBuddy's description.
  Done: six buckets by area of the selected size. Big & Untouched is files
  older than 365 days, capped at 100. Stage Selected uses
  `CleanupQueue.stage` with reason `big & untouched`. Still Trash-only on
  confirm. Bucket assignment is a `DiskMapCore` function with a test.
- [x] **TASK-014: Folders view** — plain browsable list/grid, sized as you
  navigate, closest to Finder's own list view but annotated with size.
  Done: children of `currentNode`, sorted by the selected totals, breadcrumb
  back. Files do not drill. No second scan.

  For each, prompt template: *"Implement a [X] view as [X]View.swift in
  Sources/DiskMapApp, consuming tree.children(of:totals:) the same way
  TreemapContainerView does. Add it as a tab/picker option alongside the
  existing treemap in ContentView. Write it so switching views doesn't
  re-scan — reuse the existing `tree`/`totals` state."*

## Milestone 4 — App uninstaller + Quick Wins

- [x] **TASK-015: Applications browser + leftover UI**
  Prompt: *"Build an AppsView.swift listing /Applications and
  ~/Applications, using AppLeftoverFinder.findLeftovers for the selected
  app, displaying bundle size + leftover size + leftover path list, with a
  'Stage for removal' button wired to CleanupQueue."*
  Done: Apps page lists `/Applications` and `~/Applications`. Stage
  sends the bundle and each leftover through `CleanupQueue` with its
  allocated size. Nothing is removed from this page.

- [x] **TASK-016: Configurable Quick Wins scan**
  Prompt: *"Add a `quick-wins-patterns.json` (repo root or bundled
  resource) listing regenerable directory names (node_modules, .venv,
  target, .next, dist, build, DerivedData, ~/Library/Developer/Xcode/iOS
  DeviceSupport, common cache paths — see docs/PRD.md's 'do better' section
  for why this should be data, not code). Implement a scan that walks the
  already-built FileTree looking for directory names matching the list,
  totals them, and surfaces results the moment a scan lands, per
  DiskBuddy's description."*
  Done: `Sources/DiskMapCore/quick-wins-patterns.json`, walked on the
  existing tree. A match swallows descendants so `dist` inside
  `node_modules` is not counted twice. Stage Selected uses the cleanup
  queue. No second scan.

- [x] **TASK-017: Cleanup queue UI**
  Prompt: *"Build a CleanupQueueView.swift: a resizable list of everything
  currently staged in CleanupQueue, grouped by reason, with a running total
  size, a Quick Look button per item (QLPreviewPanel), remove-from-queue,
  and a final confirm button that calls CleanupQueue.commit() and reports
  per-item success/failure."*
  Done: Cleanup page, grouped by reason, reclaimable total, Quick Look,
  remove-from-queue, confirm moves to Trash and reports per-item
  success or failure. Still `trashItem` only.

## Milestone 5 — Snapshots

- [x] **TASK-018: Snapshot serialization**
  Prompt: *"Design and implement Snapshot.swift: serialize a FileTree +
  its rolled-up totals to disk (propose a compact binary format or SQLite
  — document the choice in docs/ARCHITECTURE.md's decision log either
  way), keyed by scan root path + timestamp."*
  Done: versioned binary `DMAP` file, not SQLite. Stored under Application
  Support `DiskMap/snapshots`, keyed by root path and timestamp. Listing
  reads the header only. Choice is in the architecture decision log.

- [x] **TASK-019: Snapshot diff view**
  Prompt: *"Build a view comparing two snapshots of the same root,
  surfacing which folders grew/shrank and by how much, sorted by absolute
  change."*
  Done: Snapshots page saves the current scan and diffs two files of the
  same root. Folders match by path. A folder on only one side is a full
  grow or shrink. Sorted by absolute change. Reopening a snapshot in the
  treemap is not part of this.

## Scan speed

The enumerator walk (373 s, 1.65M items) was replaced with
`getattrlistbulk` and worker threads. Release home scan 2026-09-14:
1,791,180 items in 7.312 s, 17 not-downloaded. File sizes still match
`URL` resource values on the scan fixture. Symlinks are still skipped.
A `chmod 000` directory is still recorded with no children. Excluded-path
prefixes were not changed.

- [x] **TASK-024: Scan pipeline + capacity prep**
  Done on `perf/scan-and-runtime` (2026-09-14):
  - Dedicated publisher thread owns all `FileTree` inserts; scan workers
    only run `getattrlistbulk` and submit batches (no shared insert lock
    on the hot path).
  - `FileTree.reserveNodeCapacity(_:uniqueNames:)` pre-sizes packed
    arrays and the UTF-8 intern table (~2M nodes / ~750k names).
  - `rollUpSizes` is iterative post-order (no per-node recursion).
  - `DiskMapScanBench` release home scans (same machine, ~1.80M items):
    best **6.035 s**, typical band ~8.9–10.9 s (disk cache variance is
    large — original getattrlistbulk code also spanned ~6.4–9.9 s in
    back-to-back controls). Walk-peak RSS dropped from ~340 MB class to
    **~212 MB** steady across five runs.
  - Tried `openat` fd-handoff for child dirs; it *regressed* wall time
    (~10 s flat) and was reverted. Path strings stay on the job.
  - Do not re-run TASK-002c memory experiments as a goal.

- [x] **TASK-025: Stable benches, UTF-8 paths, rollUpBoth, worker/buffer defaults**
  Done on `perf/scan-and-runtime` (2026-09-14). Playbook + raw runs:
  `docs/PERF.md`, `docs/perf-results/`.
  - `DiskMapScanBench --repeat/--rollup/--json/--label`
  - Child jobs carry NUL-terminated UTF-8 paths (no hot-path `String` join)
  - `FileTree.rollUpBoth()`; ContentView uses it (~30 ms on home tree)
  - Synthetic bushy-tree + optional `/Volumes` smoke tests (42 tests total)
  - A/B: workers **8** median 6.038 s (4→8.86 s, 12→9.91 s); buffer **4 MB**
    median 6.166 s vs 1 MB 9.682 s. Defaults set to match.
  - Confirm-defaults after the change: see `docs/perf-results/confirm-defaults.txt`
  - **Cold matrix done** (2026-09-13 post-reboot, ~1.75M items):
    cold min/median/max **5.878 / 10.506 / 11.866** s;
    warm follow-up **8.500 / 9.855 / 10.190** s.
    Raw: `docs/perf-results/cold-home-post-restart.txt`,
    `warm-home-post-restart.txt`. Details in `docs/PERF.md`.
  - **Phase 1–4 done** (2026-09-13): packed UTF-8 name blob; publisher
    sharding no-go (`sample`, no Xcode); MD5 partial + streaming SHA256;
    `--layout` first-paint stand-in 91 ms (no UI fix). See `docs/PERF.md`.



## Milestone 6 — Maximize, then ad-hoc build (re-sequenced)

TASK-020/021 (paid Developer Program + notarization) deferred — ad-hoc
signing needs no Apple account. Revisit only if this goes to more than
one Mac. TASK-022 (auto-update) deprioritized for the same reason.

- [x] **TASK-026: Feature-completeness audit against docs/PRD.md**
  Done 2026-09-14: `docs/PRD-AUDIT.md`. Biggest confirmed gap was
  external/network volume confirmation (addressed in TASK-027 for ExFAT;
  network share still N/A on this machine).

- [x] **TASK-027: External volumes + edge-case robustness pass**
  Done 2026-09-14: `docs/EDGE-ROBUSTNESS.md`. RAM ExFAT volume (because
  `hdiutil create` is TCC-blocked). `F_LOG2PHYS_EXT` → errno 45;
  CloneDetector false; DuplicateFinder hashes. Unicode / deep path /
  chmod 000 / 64 MB file OK. Script: `scripts/make-exfat-fixture.sh`.

- [x] **TASK-028: DuplicateFinder memory-at-scale benchmark**
  Done 2026-09-14 on `~/Downloads` (~23.7k items, 20 080 candidates):
  dup elapsed **0.331 s**, rss_before **72.4 MB**, rss_peak_sampled /
  after **140.0 MB**, full_hash_calls **748**, groups **281**.
  Raw: `docs/perf-results/downloads-duplicates-rss.txt`.
  Peak is modest; no TaskGroup concurrency throttle added. Home-scale
  re-run still useful later if Downloads is not representative of large
  media trees.

- [x] **TASK-029: Ad-hoc build & package script**
  Done: `scripts/build-adhoc.sh` → `dist/DiskMap.app`, ad-hoc signed
  (`com.ayushjo.diskmap`). Documented in SETUP.md (right-click → Open).

### Still deferred

- [ ] **TASK-020: Apple Developer account + signing**
- [ ] **TASK-021: Notarization pipeline**
- [ ] **TASK-022: Update mechanism**
- [ ] **TASK-023: App icon + visual polish pass**

- [x] **TASK-030: DiskBuddy-parity Explore shell (Treemap checkpoint + 8 view-modes)**
  Done 2026-09-13 on `perf/scan-and-runtime`. Supersedes the old TASK-030/031
  polish split: one Explore screen owns all 8 viz modes; top nav is
  Explore | Duplicates | Applications | Monitor (stub) | Snapshots.
  Quick Wins lives as an ambient sidebar panel (not a top-nav page).
  - Core: `VolumeStats` (`statfs`), `FileTypeCatalog` +
    `file-type-categories.json`, `ChartLayout.slices(..., otherFraction:)`
  - App: cream `#FAF5EC` / ink `#1C1B17` in `DesignSystem.swift`;
    `ExploreShellView` (sidebar + view-picker + canvas + inspector);
    Treemap with By folder/type/age coloring; depth slider drives
    `otherFraction` for sunburst/flame/bubbles/mind map
  - Inspector: DETAILS (Compressed by = logical − on disk), Largest Inside,
    Reveal / Quick Look / Focus / Copy Path, Add to Cleanup. Created wired to `FileTree.createdDay` (TASK-031).
  - `swift test`: 46 green. DiskMapCore layout math unchanged beyond the
    additive `otherFraction` parameter.


- [x] **TASK-032: Explore Batch A — Folders / Top Sizes / Age Map**
  Done 2026-09-14 (`10dc869`): selection sync into Inspector; cream row chrome.

- [x] **TASK-033: Explore Batch B — Sunburst / Flame / Bubbles / Mind Map**
  Done 2026-09-14 (`61204fb`): shared ExploreColoring; depth → otherFraction.


- [x] **TASK-034: Explore cream contrast polish**
  Done 2026-09-14: force light color scheme; replace semantic `.secondary`/`.primary`
  on cream with ink/mutedLabel so Inspector/File Types/Quick Wins/Largest Inside
  labels stay readable under system Dark Mode. Bubbles label threshold raised.


- [x] **TASK-035: Explore click lag + Cleanup UX + list/canvas polish**
  Done 2026-09-14: post-scan `rollUpDescendantCounts` + cached Quick Wins /
  File Types (no full-tree walk on every selection). Cleanup confirm dialog,
  toast, disabled when already staged. Folders/Top Sizes denser rows; chart
  labels use ink on pastels with truncation.
