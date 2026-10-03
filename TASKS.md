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

## Search + developer storage view (2026-09-19)

- [x] **Find-as-you-type search.** `FileSearchIndex` in DiskMapCore —
  substring match runs once per interned name, node ids are grouped by
  name id with a counting sort, results ranked by size through a bounded
  insert (no full sort). Search page in the sidebar: kind filter
  (All/Folders/Files), ranked live results, Show-in-map jump, double-tap
  reveal. Index builds once per scan (keyed on `ScanModel.scanID`).
- [x] **Developer page.** `quick-wins-patterns.json` now carries
  categories (JavaScript, Python, Rust, JVM, Go, Ruby, Flutter/Dart,
  Xcode/iOS, macOS caches). `QuickWins.findCategorized` walks the tree
  once and attributes each hit to a category; Developer page groups hits
  per ecosystem with a why-it's-safe note and per-category Stage All.
  The flat Quick Wins page still uses the union of all categories; the
  old flat JSON shape still decodes.
- [x] **Interactive age map.** Tap a heatmap bucket to filter the file
  list to that age band (`AgeMap.files`); tap again or Clear to revert
  to Big & Untouched.
- [x] **Main-actor fixes.** Quick Wins / Age Map aggregations were
  computed properties re-running on every render — now cached state
  computed once per scan, off-actor. Snapshot save/load/diff, duplicate
  candidate collection, and Apps leftover lookup moved to detached
  tasks. Duplicate candidates are size-colliding only, so `tree.path`
  building skips files that can never match. Roll-ups run off-actor.
- [x] **UI fixes.** Choose Folder disabled while a scan is in flight
  (was a second concurrent scan). iCloud (not-downloaded) icons on file
  rows in Folders / Top Sizes / Age Map / Search. Double-tap a file in
  the treemap reveals it in Finder. Cleanup commit report is bounded in
  a scroll view instead of growing without limit.

## Scan performance (2026-09-13/14)

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

## Milestone 7 — Trust pass (correctness)

Plan: `~/.claude/plans/okay-make-a-plan-shiny-hearth.md`; feature rationale in
`docs/ROADMAP-NEXT.md`. Everything in this milestone fixes a number the user
already sees. TASK-036 is the blocker: TASK-037 and TASK-038 both need file
identity to exist.

- [x] **TASK-036: Scan identity — file ID, link count, mount containment**
  `FileTree` records no identity at all (`docs/audits/BIGGEST-FILES-OVERVIEW-AUDIT.md`:
  "Identity: Path-only"), so a file reachable under five names counts five
  times everywhere. `NodeFlags.apfsClone` / `NodeFlags.hardLink` are declared
  and never set. Product spec §39 requires inode-aware accounting.
  Add `ATTR_CMN_DEVID`, `ATTR_CMN_FILEID`, `ATTR_FILE_LINKCOUNT` **and**
  `ATTR_DIR_LINKCOUNT` to the `BulkScan` mask. The dir link count is not
  cosmetic: without it the file section is 4 bytes wider than the dir section
  and `parse()` loses the single-offset-pair symmetry at `BulkScan.swift:155-161`.
  Store `fileID` as a new `[UInt64]` (+8 B/node); fold `linkCount > 1` into the
  existing unused `NodeFlags.hardLink` bit (free); do **not** store devid — use
  it in `publish()` only, to stop descent across mount points.
  Acceptance: `AttrProbe` output checked into `docs/perf-results/` showing the
  real offsets for a file record and a dir record; `fixedPrefix` derived from
  the probe, not hand-computed; `swift test` green; bench `--repeat 5 --rollup`
  min/median/max recorded in `docs/PERF.md` proving the wider records did not
  regress the walk; zero extra syscalls; snapshot codec bumped 2 → 3 with a
  v2-compat read path.
  Prompt: *"Read `.cursor/rules/020-verify-unverified-code.mdc` and the
  CloneDetector/TASK-005 precedent first. Add an `AttrProbe` executable target
  that calls `getattrlistbulk` with the new mask on a known file and a known
  directory, hexdumps one record each, and prints the byte offset of every
  field. Use that output — never a hand-derived table — to update `parse()`
  and `fixedPrefix` in `BulkScan.swift`. Add `fileID` to `FileTree` with
  defaulted `addNode` parameters so existing tests still compile. Set
  `NodeFlags.hardLink` where `notDownloaded` is set today. Skip descent when a
  child's devid differs from the scan root's, behind a `crossMounts: Bool =
  false` option. Bump the snapshot version and keep v1/v2 readable."*

- [x] **TASK-037: Hard-link-aware rollups**
  `rollUpSizes(basis:)` / `rollUpBoth()` sum unconditionally, so N hard links
  to one inode inflate every ancestor total, treemap area and folder figure.
  Do not add a set-membership test on 1.8M nodes: hard links are rare, so
  collect only nodes with `NodeFlags.hardLink` set, group by `fileID`, charge
  the lowest node id once, and subtract the rest from their ancestor chains.
  O(hard-linked nodes × depth); common path untouched.
  Acceptance: new tests in `BiggestFilesAccountingTests.swift` build a real
  `link(2)` fixture and assert the parent counts it once. There is currently
  **no hard-link test anywhere** in the suite. Expose the correction as a named
  figure so Overview can explain it rather than silently differing from `du`.
  Prompt: *"Add hard-link-aware rollups to `FileTree`. Single pass collecting
  `NodeFlags.hardLink` nodes, group by fileID, charge once. Return the
  correction alongside the totals. Add a `link(2)` fixture test asserting a
  parent folder counts a two-name inode once."*

  **Done 2026-09-25** on `feat/trust-pass`.
  - Offsets MEASURED by the new `AttrProbe` target, not derived:
    `docs/perf-results/attr-probe.txt`. `fixedPrefix` 92 → 108; DEVID at 36,
    FILEID at 80, LINKCOUNT at 88, sizes at 92/100.
  - Confirmed the design bet: requesting `ATTR_DIR_LINKCOUNT` keeps the dir
    and file sections the same width (20 B at offset 88), so `parse()` keeps
    one offset pair and stays branch-free.
  - **Caveat found by measuring:** `ATTR_DIR_LINKCOUNT` reads 1 on APFS even
    for a directory with 3 children whose `st_nlink` is 5. We request it only
    for layout symmetry and never trust its value. Only `ATTR_FILE_LINKCOUNT`
    is used, and only for files.
  - `FileTree.fileID: [UInt64]` (+8 B/node, stride 42 → 50). Link count rides
    the previously-declared-but-never-set `NodeFlags.hardLink` bit — no second
    array. Device id is not stored; it is consumed in `publish()` only.
  - Mount containment: a directory on another device is recorded but not
    descended unless `crossMounts: true`. `ScanEngine.Result` gains
    `hardLinkCount` and `crossMountSkipCount`.
  - Free win: `CanonicalPath.mayContainFirmlinkTwins` hoists the firmlink
    check out of the per-directory path, so a home scan no longer builds and
    discards ~200k path Strings on the publisher thread.
  - Snapshot codec v2 → v3; v1/v2 still decode with fileID 0.
  - **Perf A/B against the pre-change commit on the same 2.05M-item tree**
    (the old 1.79M numbers are not a valid control — the tree grew):
    median **6.932 s → 6.993 s (+0.9%)**, min 6.916 → 6.847. Inside noise,
    zero extra syscalls. Raw: `task036-identity.txt`, `baseline-pre036.txt`.
  - `swift test` 108 green, including `ScanIdentityTests` — the suite's first
    hard-link coverage.

  **Done 2026-09-25** (TASK-037) on `feat/trust-pass`.
  - Suppression applied inside `ownSize`, so the existing post-order walk
    yields corrected totals with no second pass and no ancestor fixup.
  - The duplicate name reads 0 rather than keeping its size while being
    withheld from its parent — otherwise `sum(children) != parent` and the
    treemap overflows its rect. `NodeFlags.hardLink` lets the UI explain it.
  - Election is by **lowest path, not lowest node id**: ids and sibling order
    both depend on worker-thread interleaving, so an id-based choice would
    make snapshot diffs show a file moving between folders when nothing
    changed. Paths are built only for the ~0.7% flagged nodes.
  - A file whose other name lives outside the scan root keeps its full size
    (group of one) — suppressing it would under-report real usage.
  - **Real-world correction on the home tree: 4 525 inodes, 10 428 duplicate
    names, 766 058 496 bytes (~730 MiB) that were being double-counted.**
    Raw: `task037-hardlinks.txt`.
  - Cost: `rollUpBoth` ~0.028 s → ~0.042–0.053 s, still far under the 100 ms
    first-paint bar. Trees with no hard links allocate nothing.
  - `swift test` 116 green, including `HardLinkRollupTests` (cross-folder,
    insertion-order stability, linked-outside-tree, distinct-inode, and a real
    `link(2)` end-to-end scan).

- [x] **TASK-038: True reclaim math at the cleanup boundary**
  The number shown at the moment of the destructive action is wrong for clones
  and hard links. `CleanupQueue` already has `sharesStorageGroup` /
  `groupCopyCount` / group logic in `totalSize()` — but `DuplicatesView.swift:279`
  is the **only producer of it in the app**. Every other staging surface (Safe
  to Review, Forgotten, Caches, Old Downloads, Large Media, Apps, Age Map, File
  Browser, Quick Wins, Explore) stages with the defaults, so shared bytes count
  at full size in the same "This will free about X" dialog
  (`CleanupQueueView.swift:128`).
  Make sharing something the queue **derives**, not something callers must
  remember to pass: `stage()` does one `lstat` and records `(st_dev, st_ino,
  st_nlink)`; `totalSize()` charges a hard-link inode only once its staged
  count reaches `st_nlink` (the same shape as the existing clone rule, so they
  unify); clones are resolved by `CloneDetector` pairwise over staged items of
  equal size only, with the extent map **memoized by path** (it is currently
  re-read on every call, and `DuplicateFinder.partitionClones` calls it O(k²)
  with no cache). Keep `sharesStorageGroup` as an accepted hint.
  Also fix: `CleanupPreflight.logEntries` uses raw `item.size`, so the
  post-commit receipt re-inflates clones even on the correct path; and
  `DuplicateGroup.sizeEach` uses `logicalSize` while the UI basis is
  `.allocated` — pick one, document it in `ARCHITECTURE.md`, make both agree.
  Acceptance: extend `CleanupQueueReclaimTests` — staging 4 of 5 hard links
  frees 0 and the 5th frees `size` once; a clone staged from a non-Duplicates
  surface reports shared, not full, size; the commit receipt equals the
  pre-commit estimate; ExFAT/non-APFS (`fcntl` errno 45) degrades to
  "independent" without crash or hang. Do not weaken the existing conservative
  all-or-nothing rule — instead make the UI explain it.
  Prompt: *"Move shared-storage detection into `CleanupQueue` so every staging
  surface gets it for free. `stage()` lstats and stores dev/ino/nlink.
  `totalSize()` charges hard links once per inode when all names are staged,
  and runs memoized `CloneDetector` comparisons across equal-size staged items.
  Thread the true total into the commit receipt. Add tests per the acceptance
  criteria. Do not modify `CleanupQueue.excludedPrefixes`."*

  **Done 2026-09-28** on `feat/trust-pass`.
  - **Deviation:** used APFS's own accounting (`ATTR_CMNEXT_PRIVATESIZE`,
    `CLONEID`, `CLONE_REFCNT`) instead of pairwise `CloneDetector`; it is exact,
    and it also sees blocks held by local snapshots. Semantics measured by the
    new `SharingProbe` target (`docs/perf-results/sharing-probe.txt`).
  - `StorageSharing` profiles each staged path; `CleanupQueue` derives sharing
    itself, so every staging surface is correct with no call-site changes.
    Rules: private bytes count; a hard-linked inode counts once when every name
    is queued; a clone family counts its shared blocks once when every member
    is queued; items inside a queued folder count once, via the folder.
  - Real case the plan missed: **pnpm hard-links `node_modules` into its global
    store**, so trashing it frees almost nothing; the app used to promise the
    full size. Covered by a test.
  - Receipt now reports what actually moved (recomputed over successes), and
    folders move first with their contents reported as "moved with its folder"
    instead of retried and shown as failures.
  - Copy fixed: moving to the Trash frees nothing until it is emptied. The
    queue says "freed when you empty the Trash", with "at least" when shared
    blocks cannot be attributed, and how much stays in use by unqueued copies.
  - Duplicates: reclaim figures use on-disk size (new
    `reclaimableBytes(deleting:onDisk:)`); `sizeEach` stays the logical
    matching key. Two names of one hard-linked inode are no longer offered as
    duplicates of each other.
  - Traps caught by testing on real volumes: bulk directory records omit file
    attributes (a length check silently dropped batches); FSKit ExFAT claims
    to return the extended attributes and fills them with zeros, so they are
    trusted only on `apfs`. Verified on a RAM-backed ExFAT volume.
  - Staging is non-blocking: folders are measured in the background
    (single-threaded walk ~9.6 s for a 325k-file `~/Library/Caches`), the
    estimate is flagged `isCalculating`, and **Move to Trash is disabled until
    the real figure is known**. Making the walk parallel is still open.
  - 140 tests green (new `ReclaimMathTests`, 22 cases), 12/12 stability runs.

  **TASK-041 done 2026-09-28.** One-line fix, plus the app's first test target
  (`Tests/DiskMapAppTests`) so `ScanModel` can be tested at all; the regression
  test stages a real Old Downloads catalog and checks it survives
  `refreshDeveloperCache()` with no tree.

- [x] **TASK-039: Surface unreadable directories**
  `BulkScan.swift:87` swallows `open()` failures — `errno` is never captured
  and nothing in `Sources/` counts or reports them, so a scan without Full Disk
  Access reports confidently wrong totals with no indication.
  Capture `errno` immediately; distinguish `EACCES`/`EPERM` from `ENOENT`
  (raced deletion) and `ELOOP`/`ENOTDIR` (expected under `O_NOFOLLOW`). Rename
  `noteEmptyDirectory` → `noteUnopenedDirectory(errno:nodeID:)` — the current
  name is wrong, since a genuinely empty readable directory goes through
  `submit()` with zero entries. Keep the `inflight -= 1` + `signalWorkLocked()`
  pair intact; it drives scan termination. Record node IDs, not strings.
  Thread through `BulkScan.Result` → `ScanEngine.Result` (make it `public`) →
  `ScanModel`, assigned next to `lastScanSeconds` (it comes from `result`, not
  `prepared`, so `PreparedScan` needs no new field). Surface as an inline
  notice with a button to the Full Disk Access pane — the app has no `.alert(`
  anywhere and prefers banners; reuse `WhyCard` or factor the four hand-rolled
  banners into one `DiskMapNoticeBanner`.
  Acceptance: `ScanEngineTests.swift:221-224` already builds a `chmod 000`
  fixture — assert the count there. `swift test` green.
  Prompt: *"Capture and report directories the scan could not open. Follow the
  chain BulkScan.State → BulkScan.Result → ScanEngine.Result → ScanModel → an
  inline notice banner. Distinguish permission-denied from raced-deletion and
  from symlink-under-O_NOFOLLOW. Add the count assertion to the existing
  chmod-000 test."*

- [x] **TASK-040: Volume reconciliation in Overview**
  Both numbers already live in `AnalysisSnapshot` — `volume?.usedBytes` from
  `statfs` and `scannedBytes` from the root rollup — and nothing compares them.
  Add `unaccountedBytes` / `coverageFraction` (update `static let empty`) and a
  row in `OverviewView.headerCard` under the free line and above
  `SegmentedStorageBar`; today the `vol != nil` branch discards `scannedBytes`
  entirely, so this is the first place both appear together.
  Copy must be honest that the gap is several causes — APFS local Time Machine
  snapshots, purgeable space, other volumes and users, `/System`, and the
  unreadable directories from TASK-039 — not one. Note the basis mismatch:
  `scannedBytes` follows `sizeBasis`, `usedBytes` is always `total - f_bavail`.
  Acceptance: `AnalysisSnapshotTests` covers the new computed values including
  the `volume == nil` case; the invariant at `AnalysisSnapshot.swift:226-229`
  ("never inflate Other to fill volume") still holds.
  Prompt: *"Add volume-vs-scanned reconciliation to `AnalysisSnapshot` and show
  it in `OverviewView.headerCard`. Be explicit in the copy about what the
  unaccounted bytes actually contain. Do not inflate any category to close the
  gap."*

  **TASK-039 done 2026-09-28.** `errno` captured inside the `open(2)` closure;
  `noteEmptyDirectory` → `noteUnopenedDirectory(errno:nodeID:)` (the old name
  was wrong — empty readable folders never took that path). EACCES/EPERM are
  reported as `deniedDirectoryIDs`; ENOENT (deleted mid-scan) and other
  failures are counted separately and not shown as problems. Overview shows a
  persistent `DiskMapNoticeBanner` with example paths and a button that opens
  the Full Disk Access pane (it only opens it). **A real home scan without FDA
  skipped 144 folders** — previously silent, with every total above them short.
  Tests: exact denied-id assertion on the chmod-000 fixture, a 4-sibling count,
  and an app-level test that `ScanModel` exposes readable example paths.

  **TASK-040 done 2026-09-28.** `AnalysisSnapshot.scannedOnDiskBytes` (always
  allocated, since `statfs` is on-disk) and a computed `reconciliation`: used,
  scanned, unaccounted (clamped at 0), `scannedExceedsUsed`, coverage. The
  Overview header now says "This scan accounts for X of the Y in use" and names
  every possible cause of the gap — outside the scanned folder, local Time
  Machine snapshots or purgeable space, and unreadable folders — never implying
  one. Clones listed once per copy can make a scan exceed "used"; that case is
  explained instead of going negative. The "never inflate Other" invariant
  holds: the gap is its own figure, not a category.

  **Visual check:** new `SnapshotHarness` (`--snapshot-dir`) renders the app's
  own window to PNG in-process — no Screen Recording permission, nothing else
  on screen captured. Used to confirm both notices render in the real app.

- [x] **TASK-041: Fix `refreshDeveloperCache` clearing the wrong cache**
  `ContentView.swift:426-431` — the guard's else-branch also clears
  `cachedOldDownloads`, misindented, a copy-paste slip none of the four sibling
  methods share. Visiting Developer Storage before totals are ready silently
  wipes the Old Downloads catalog. One line, but load-bearing once TASK-043
  makes "empty" the normal pre-build state rather than an error state.
  Acceptance: `swift test` green; a regression test that calling
  `refreshDeveloperCache()` with no tree leaves `cachedOldDownloads` untouched.

- [x] **TASK-065: Walk-termination race — scans could silently drop a subtree**
  Found while stabilising TASK-036/037; **pre-existing**, not introduced by
  them. `signalWorkLocked` ended the walk on
  `inflight == 0 && jobs.isEmpty && batches.isEmpty`, ignoring a batch the
  publisher had already taken but not yet turned into child jobs (it unlocks
  for the whole of `publish()`).
  Sequence: publisher pops a directory's batch and unlocks → a worker fails to
  `open()` an unreadable sibling and calls `noteUnopenedDirectory`, which drops
  `inflight` to 0 **without** adding a batch → all queues read empty →
  `finished` set → every worker exits → the publisher appends child jobs that
  nobody will ever scan. **The scan returned a tree missing an entire subtree
  and reported success.** Unreadable directories are the only path that
  decrements `inflight` without producing a batch, which is why this would bite
  hardest on a full-disk or `~/Library` scan without Full Disk Access — exactly
  where the totals matter most.
  Fix: `State.publishing` counts batches in the publisher's hands, incremented
  under the lock before it unlocks, decremented only after children are
  enqueued, and included in the termination condition.
  **Evidence.** Full suite before: **8 failures in 30 runs** (3/15 on the
  untouched parent commit 8190439, 5/15 mid-trust-pass). After: **1 in 70**.
  New `ScanTerminationTests` reproduces it **deterministically** on the
  unfixed commit (9 failures in 9 attempts, deepest leaf `nil`) and passes on
  the fix; it scans a deep chain beside four unreadable siblings 40 times and
  asserts both that the leaf survives and that the node count never varies
  between identical scans.
  Note this was never recorded anywhere before — grep of `docs/` and `TASKS.md`
  for "flaky"/"race" returned nothing, so it had been shipping unnoticed.

- [x] **TASK-066: Scans could hang forever under concurrency (thread starvation)**
  Found 2026-09-28 when a full-suite run never returned. **Pre-existing.**
  `ScanEngine.scan` ran the blocking `BulkScan.walk` inside `Task.detached`
  (Swift's cooperative pool) and its workers/publisher on
  `DispatchQueue.global`. Both pools cap runnable threads per QoS, and the
  kernel keeps counting a cooperative thread parked in `group.wait()` as
  active. With more scans than cores in flight, every slot held a walk waiting
  on workers that could never be scheduled. `sample` of the hung process:
  11 threads in `_dispatch_group_wait_slow` inside `BulkScan.walk`, **zero**
  worker threads, **zero** publisher threads. In the app, `cancelScan` leaves
  the old walk running, so cancel-and-rescan stacks walks the same way.
  Fix: coordinator, workers and publisher run on dedicated `Thread`s
  (`BulkScan.startScanThread`, named `DiskMap.scan.*`); `ScanEngine.scan`
  resumes via `CheckedContinuation`, so no Swift-concurrency thread ever blocks
  on a scan. `ScanTerminationTests.manyConcurrentScansAllFinish` runs
  cores×2+4 scans at once: hung >10 min on the unfixed commit with the same
  thread signature, ~0.3 s fixed. Caveat recorded in the test: a regression
  hangs the suite rather than failing it, because Swift Testing's time limit is
  enforced on the same starved pool.

- [x] **TASK-067: Freshly edited APFS clones were reported as identical**
  Found 2026-09-28 via an intermittent `CloneDetectorTests` failure.
  **Pre-existing.** APFS allocates the copy-on-write block at writeback, so
  until the edit is flushed `F_LOG2PHYS_EXT` still reports the shared extent.
  `DuplicateFinder` trusts that to skip hashing, so a clone edited shortly
  before a duplicate scan was grouped as a byte-identical copy of a file it no
  longer matched. Measured under load: 18/320 (8 MB) and 22/200 (64 KB) wrong
  unfixed; 0/320 with a reader-side `fsync` on the read-only descriptor before
  mapping. Fix is that `fsync`; failure returns `nil` → content hashing.
  `freshlyEditedClonesAreNeverReportedAsClones` fails 15–22/200 on the unfixed
  code and passes fixed — it must clone with `/bin/cp -c`, since in-process
  `clonefile()` never reproduced it (0/600), so a clonefile-based test would
  have passed on the bug. Duplicates bench on `~/Downloads` after the fix:
  0.290 s for 16 441 candidates (0.331 s for 20 080 before) — no visible cost.

- [x] **TASK-068: `swift test` broken by Command Line Tools 26.6**
  CLT 26.6 (installed 2026-09-25 11:15, Swift 6.3.3) ships Swift Testing as
  `Testing.framework`; SwiftPM passes its directory with `-I`/`-L` but not
  `-F`, so every test file fails with `no such module 'Testing'`, and the
  binary also needs rpaths for the framework and `lib_TestingInterop.dylib`.
  Added `scripts/test.sh` (adds the flags only when that CLT layout exists, so
  it is a no-op under Xcode) and pointed AGENTS.md, the diskmap skill, the
  Cursor overview rule and CI at it. `unsafeFlags` in `Package.swift` was
  rejected — it would bake one machine's paths into the package.
  Also fixed `taskInfoReturnsResidentAndPeak`, which asserted
  `resident_size_max >= resident_size` within one read; the kernel updates the
  high-water mark lazily (seen 1 run in 15). It now asserts the mark exists and
  never decreases between reads.

## Milestone 8 — Measure before optimizing

- [x] **TASK-042: `DiskMapScanBench --phases`**
  `docs/PERF.md` times the walk (~6 s), `rollUpBoth` (~30 ms) and layout
  (91 ms) but **not** the eight catalog builds between them — exactly the
  stretch between "scan finished" and "UI appears", and the one unmeasured hole
  in the log. Extend `RunRow` with per-phase timings: walk, rollUpBoth,
  rollUpDescendantCounts, QuickWins, FileTypes, AnalysisSnapshot,
  ForgottenFiles, ReviewableCatalog, DeveloperCatalog, OldDownloadsCatalog,
  MediaCatalog, layout.
  Do this **before** Milestone 9 — it either finds a second of hidden latency
  or retires the hypothesis cheaply.
  Acceptance: `--phases` run checked into `docs/perf-results/`, min/median/max
  per phase in `docs/PERF.md`.

  **Done 2026-09-28** on `feat/speed`. Home, 2.25M items, 5 runs: walk median
  **8.36 s**, post-walk pipeline median **8.88 s** — longer than the walk.
  MediaCatalog 3.79 s and OldDownloadsCatalog 2.84 s are 6.6 s of it and each
  backs one screen; DeveloperCatalog 0.93 s, FileTypes 0.61 s, AnalysisSnapshot
  0.33 s, the rest < 0.12 s each. First paint needs only ≈1.1 s of it. Full
  table in `docs/PERF.md`.

## Milestone 9 — Perceived speed

- [x] **TASK-069: Stop building a path per node in the catalogs**
  Found by TASK-042. OldDownloads, Media and FileTypes spent seconds building
  full paths for (nearly) every node only to substring-test or discard them.
  Replaced with `FileTree.folderChainFlags` (one forward pass over folder
  names), name-first matching with top-N candidate building, and per-distinct-
  name extension resolution. **Output proven byte-identical** on a frozen real
  home scan (`--save-snapshot` / `--from-snapshot` / `--catalog-dump`,
  2 413 lines). Live home post-walk pipeline **8.88 s → 2.52 s**: Media
  3.79 → 0.52 s, OldDownloads 2.84 → 0.10 s, FileTypes 0.61 → 0.22 s.

- [x] **TASK-043: Lazy catalogs**
  `ContentView.swift:194-218` builds all catalogs sequentially before first
  paint, and `isScanning = false` only flips after all seven are assigned — so
  the user stares at a frozen "Almost there…", a frozen count and an
  indeterminate spinner for the whole catalog window.
  The view layer is already done: all five catalog views (plus
  `CachesReviewView`) already have `.task { if cache.isEmpty, model.tree != nil
  { refresh() } }`. Delete the seven per-screen fields from `PreparedScan` and
  their eager builds; keep only what Overview/Explore need (rollUpBoth,
  rollUpDescendantCounts, QuickWins, FileTypes, analysis).
  Two prerequisites: the five `refresh*Cache()` methods are synchronous on
  `@MainActor` and would now beach-ball on the primary path — make them `async`
  + `Task.detached`, following `refreshQueue()`; and the `isEmpty` guard
  conflates "not built" with "genuinely empty", so a user with no old downloads
  would rebuild on every visit — add an explicit built/not-built sentinel.
  Also invalidate caches explicitly on rescan (`scan()` skips clearing when
  `hasCommittedScan`, relying on reassignment that will no longer happen).
  Free fix: the eager path builds from `both.allocated` while `refresh*` builds
  from `selectedTotals`, so a logical-basis scan currently disagrees with a
  later refresh. Going lazy resolves it.
  Acceptance: `swift test` green; first paint no longer waits on any per-screen
  catalog; visiting each of the six views builds exactly once.

  **Done 2026-09-28** on `feat/speed`. `PreparedScan` now holds only first-
  paint data (rollups, counts, QuickWins, FileTypes, AnalysisSnapshot). The
  five per-screen catalogs build on first visit via
  `ScanModel.ensureCatalog`, off the main actor, with an explicit
  `readyCatalogs` set (so an empty catalog is not rebuilt on every visit) and a
  `catalogGeneration` counter that screens key their request on, so an open
  screen refreshes itself after a rescan or basis toggle. A shared
  `catalogGate` modifier shows a loading state instead of a misleading empty
  one. Also fixed: toggling the size basis only rebuilt Forgotten and
  Reviewables, leaving Developer, Old Downloads and Media stale; now every
  catalog is invalidated. The eager path used allocated sizes while refreshes
  used the selected basis — lazy builds use the selected basis throughout.
  **Measured in the real app on a 2.25M-item home: walk-finished → first paint
  0.92 s, from ~8.9 s** (TASK-042 baseline). 150 tests green, including five
  new `LazyCatalogTests` in the app test target.

- [x] **TASK-044: Streaming first paint**
  Publish a tree snapshot every ~400 ms during the walk with partial rollups so
  the treemap and Overview grow while scanning. Largest perceived-speed win
  available; needs no engine speedup. Must respect the existing
  `scanGeneration` cancellation guard.

  **Done 2026-09-28**, adapted: publishing whole tree snapshots every 400 ms
  would copy ~100 MB of node arrays per frame and slow the walk. Instead the
  publisher keeps running on-disk totals per top-level folder (each job carries
  its top-level ancestor, so attribution is O(1)) and emits a `ScanProgress`
  every 250 ms plus one final complete report: items, bytes found, items/s,
  current folder, largest top-level folders. The scanning screen shows them
  filling in live. Real home scan at 4 s: 990k items, 217.8 GB found, ~236k
  items/s, Downloads/Library/… bars growing. Final report is checked against
  the real rollup in `LiveScanProgressTests`.

- [x] **TASK-045: Remove confirmed waste in BulkScan**
  None of these move the median much — the walk is I/O-bound and `sample`
  already established that. They matter because they all sit on the single
  serialized publisher thread, the likeliest contributor to the 5.88 → 8.95 s
  spread.
  - A discarded `String` per directory: `publish()` builds a path string for
    every descendable child to feed `CanonicalPath.shouldSkipDescend`, which
    returns `false` immediately unless the root is `/` or under
    `/System/Volumes`. ~200k wasted allocations on a home scan. Hoist the root
    check to a `Bool` computed once at scan start.
  - 32 MB of pointless zeroing at startup (8 workers × a zero-filled 4 MB
    `[UInt8]`). Use `UnsafeMutableRawBufferPointer.allocate`.
  - `broadcast()` where `signal()` suffices — every enqueue/submit wakes all
    8 workers plus the publisher.
  - `ProcessMemory.current()` (a `task_info` syscall) every 4000 items inside
    `publish()`, for a bench-only statistic. Gate it or move it off the path.
  Acceptance: bench min/median/max before and after in `docs/PERF.md`; no
  behavioural change; `swift test` green.

- [x] **TASK-046: Progress that means something, and a p95 goal**
  Identical runs span 5.88 → 8.95 s (5.87 → 10.77 s in the utf8blob session).
  A user who sees 6 s then 11 s concludes the app is unreliable — that spread
  hurts more than the median. Make p95 a **tracked goal** in `docs/PERF.md`,
  not just a reported number, and use it to test TASK-045's contention
  hypothesis.
  UI: items/sec, current directory, and a post-walk phase indicator so the
  catalog window is narrated rather than frozen. `DiskMapLoadingState`
  (`SharedChrome.swift:212`) already supports a determinate bar and is unused
  by any scan UI — use it. Preserve `accessibilityIdentifier("scan-progress")`.
  Reconsider the `readyBody` interstitial: once first paint is fast, an extra
  click to "Explore storage" is friction.
  Do **not** revisit worker counts (12 < 8), `openat` fd handoff (tried,
  regressed, reverted) or publisher sharding (rejected on `sample` evidence)
  without a profile in hand.

  **TASK-045 closed 2026-09-28 — measured, no change.** The path-String item
  was already fixed in TASK-036. Instrumented the rest on a real home scan:
  workers woke only 143 times per scan (they almost never wait), the
  publisher had 72 spurious wakeups out of 164k; `task_info` cost 2 ms and the
  buffer zero-fill 5 ms. Under 10 ms of 8–11 s — not worth new lost-wakeup risk
  in a scheduler that just had two hangs fixed.

  **p95 now tracked:** bench prints `scan_p95`; 20-run baseline min 7.75 /
  median 8.01 / **p95 10.74** / max 11.57 s. Goal p95 ≤ 1.25 × median.

  **UI part done 2026-09-28** with TASK-044: the headline follows the real
  phase (walking → "Summarizing…") instead of item-count thresholds that said
  "Almost there…" at 400k items; live stats replace the indeterminate spinner;
  `scan-progress` identifier kept. The 1.6 s "Your storage map is ready"
  interstitial is removed — with first paint at ~0.9 s it was pure delay.
  p95 tracking: see TASK-045's bench notes.

## Milestone 10 — Dark mode

~100 hardcoded colour call sites across 22 files plus 18 tokens. There are zero
`Color(nsColor:)` and zero `@Environment(\.colorScheme)` uses — nothing reads
the ambient appearance. Do this before more views exist to retrofit.

- [x] **TASK-047: Consolidate the duplicated palettes first**
  Or it gets done four times. The same 8-case file-type colour switch exists in
  `BiggestFilesView.swift:330-337` **and** `:513-520` (byte-identical),
  `ForgottenFilesView.swift:594`, and `FileBrowserView.swift:803-807` with
  drifted values (`.video` is `0.62/0.40/0.90` there vs `0.55/0.35/0.85`
  elsewhere). An ad-hoc link blue appears 8× in `FileBrowserView` alone, close
  to but not equal to `DiskMapTheme.info`. `folderPastels`/`categoryColor` and
  `ExploreColoring`'s hex palette are two parallel folder-colour systems.
  `DiskMapSpace` lives in `SharedChrome.swift`, not `DesignSystem.swift`.
  `ExploreColoring.topLevelHues(tree:)` is dead code.
  Acceptance: one source of truth per palette; no behavioural change on screen.

- [x] **TASK-048: Semantic tokens with light and dark values**
  Convert `DiskMapTheme`'s literal `Color(red:green:blue:)` values to semantic
  tokens that resolve per appearance. Nine are light-only by construction
  (`cream`, `cardFill`, `cardStroke`, `inspectorFill`, `sidebarFill`,
  `navSelected`, `hoverFill`, `inspectedFill`, `ink`); the five semantic colours
  survive with contrast tuning. `InkButtonStyle:179` and `PrimaryCTAStyle:195`
  hardcode `Color.white` as foreground. Shadows are all `.black.opacity(…)` —
  light-mode elevation cues that vanish on dark and want white-at-low-alpha.
  Then delete the five `.preferredColorScheme(.light)` calls and the local
  `.colorScheme(.dark)` workaround at `OverviewView:141`, which exists only
  because the design system has no dark variant.
  Acceptance: every destination checked by hand in both appearances (dark mode
  cannot be verified by tests); `docs/ACCESSIBILITY.md` updated.

- [x] **TASK-049: Re-tune the visualization palettes, don't just re-tint**
  `ExploreColoring` encodes two cues that **invert** on dark: `.folder` fades
  descendants by opacity (reads lighter on cream, darker on near-black — the
  depth cue reverses), and `.age` uses HSB brightness 0.55–0.80 with the oldest
  bucket darkest. The `.type` palette comes from
  `Sources/DiskMapCore/file-type-categories.json` — the one palette themeable
  without touching Swift, via a second colour field in the schema.

- [x] **TASK-050: Type scale adoption**
  606 `.font(.system(size:` call sites across 27 files; `DiskMapType` is used
  only 99 times — 86% bypass the scale. Sizes cluster at 11/12/13 (405 of 606)
  and there is no 12 pt token, which likely explains 184 hand-rolled sites. Add
  one, adopt the scale, and the Dynamic Type pass listed as "still open" in
  `docs/ACCESSIBILITY.md` becomes tractable instead of a 606-site edit.

  **Milestone 10 done 2026-09-28** on `feat/dark-mode`, verified by rendering
  all 14 screens and all 8 Visualize modes in light and dark with the snapshot
  harness (`--appearance`, `--explore-modes all`).
  - TASK-047: one file-kind palette (`DiskMapTheme.kindColor`; File Browser's
    copy had drifted — documents teal instead of gold), one age ramp
    (`ageColor`; two copies with drifted saturation), the treemap folder
    palette moved into DesignSystem, stray "link blue" ×13 → `folderTint`,
    `DiskMapSpace` moved in, dead `topLevelHues` removed. Pale-blue/warm-cream
    panel fills that glared in dark mode → `infoSurface`/`reviewSurface`.
  - TASK-048: adaptive tokens via an AppKit dynamic colour (light values
    unchanged); new `onInk` for text on ink fills (13 sites were white, which
    vanishes once ink turns light); forced light schemes removed. The primary
    CTA keeps a fixed green — the lifted dark `safe` would drop white text to
    ~2.3:1.
  - TASK-049: **the real dark-mode chart bug was not the one predicted.**
    Tile labels used `ink`, which turns light in dark mode → light text on
    pastel tiles; now a fixed `tileLabel`. And translucent fills (bubble
    containers, depth fades) darken over a dark canvas, dropping label
    contrast; `DiskMapTheme.wash` composites them against the light canvas so
    tiles are opaque and identical in both appearances. The plan's claim that
    the depth fade "inverts" was wrong in itself — it reads as "recedes" in
    both — but its translucency was the problem.
  - TASK-050: `DiskMapType` scale with 12 pt (the most hand-rolled size) and
    weight variants behind one `scale`; 524 of 612 raw sizes adopted, the rest
    are icon glyphs and one-off display numbers.
  - Also: Increase Contrast variants for low-contrast tokens; a pre-existing
    legend wrap ("Dependenci/es") fixed; "1 items" pluralisation fixed; the
    scanning count no longer forces an en_US number format.

## Milestone 11 — Developer Storage v2

`DeveloperCatalog` matches directory **names** today — right skeleton, wrong
unit of analysis. All of this runs on the existing `FileTree` + totals from one
walk; no second disk pass, no network.

- [x] **TASK-051: Project roots by manifest**
  `projectFromParent: true` calls the parent of `node_modules` the project,
  which is wrong for monorepos, pnpm workspaces and nested packages. Walk up to
  the nearest `package.json`, `Cargo.toml`, `go.mod`, `pyproject.toml`,
  `Package.swift`, `*.xcodeproj`, `pubspec.yaml`, `pom.xml`. Prerequisite for
  everything below.

- [x] **TASK-052: Rebuild cost as a first-class column**
  Split reclaimable into **free** (offline, seconds — `__pycache__`, `.next`,
  `dist`), **cheap** (offline, minutes–hours of CPU — `target/`, `DerivedData`),
  **networked** (needs a live registry — `node_modules`, `.venv`, `Pods`) and
  **networked-unpinned** (as above *and no lockfile*). The last class is the one
  nobody ships and the reason to build this: "3 GB of `node_modules` with no
  lockfile — reinstalling may not reproduce what you have" is checkable, local
  and decision-changing. Detect `package-lock.json` / `yarn.lock` /
  `pnpm-lock.yaml` / `Cargo.lock` / `poetry.lock` / `uv.lock` / `Podfile.lock`.
  Per AGENTS.md rule 6, new patterns are **data** — extend
  `quick-wins-patterns.json`, do not hardcode.

- [x] **TASK-053: Git state of the owning repo**
  Read `.git/HEAD`, `.git/refs/`, `.git/config` directly — no subprocess, no
  network. Derive: is this a repo, is there an `origin`, are there local refs
  absent from `refs/remotes/origin/`. Lets the app distinguish "pushed to
  origin, fully recoverable" from "unpushed commits, do not delete". Handle
  worktrees and `.git`-as-a-file; degrade to "unknown" rather than guess.

- [x] **TASK-054: `.gitignore` as a reclaimability oracle**
  Anything git ignores is, by the repo author's own declaration, regenerable
  and untracked — a stronger signal than our hardcoded name list, and it covers
  ecosystems we have no rule for. Start **read-only** (report ignored bytes per
  repo); staging from it is a separate later decision.

- [x] **TASK-055: Tool-native cleanup recipes**
  Some of the biggest developer directories are actively wrong to Trash:
  `Docker.raw` is a single sparse disk image whose deletion destroys every
  image, volume and container at once; `CoreSimulator` folders are tracked in
  `simctl`'s own database and deleting underneath it corrupts that state.
  For these, replace "Add to Cleanup" with the real command
  (`docker system prune -a`, `xcrun simctl delete unavailable`, `brew cleanup`,
  `npm cache clean --force`, `pnpm store prune`, `go clean -modcache`), a Copy
  button, and one line on why we are not doing it for you. **Show, never run** —
  this honours the single-deletion-path rule rather than straining against it.

- [x] **TASK-056: Project ageing**
  Max `modifiedDay` over a project **excluding** its reclaimable subtrees = when
  a human last worked on it. Unlocks "23 projects untouched for 6+ months are
  holding 41 GB of dependencies" — the headline that makes people open the app.

  **Milestone 11 done 2026-09-28** on `feat/developer-v2`.
  - Rules moved to `developer-rules.json` first, with byte-identical catalog
    output on a frozen real home scan (3 393-line dump). New fields are data:
    `rebuildCost`, `lockEcosystem`, `manifests`, `lockfiles`;
    `cleanup-recipes.json` holds the tool commands.
  - TASK-051: project = nearest folder with a manifest (falls back to the
    parent; never the home folder, so a stray `~/package.json` can't claim
    every build folder). On the real home: same 500 items, zero non-grouping
    changes, 144 items regrouped.
  - TASK-052: free / cheap / networked / **networked-unpinned**. Lockfiles are
    searched up to the repository root, because pnpm/yarn/npm workspaces keep
    one at the top. `requirements.txt` counts as pinned for Python (a missed
    warning costs less than a false one).
  - TASK-053: git state from `.git` directly — pushed / no remote / branches
    differ / worktree-unknown. Copy says "committed work", because uncommitted
    changes are not checked, and "differs" can mean unpushed or not pulled.
  - TASK-054: `.gitignore` evaluator (nested files, `info/exclude`, negation,
    anchoring, `**`, classes, escapes; not the global excludes file), read-only
    "ignored by git" per repository. Indexed by literal name/extension with a
    literal and exact-final-name prefilter for globs: a 123-rule, ~200k-entry
    repo went 1.5 s → a few ms, and results were verified identical to a naive
    evaluator across all 51 project/repository lines of the real home.
  - TASK-055: recipes shown with a Copy button, never run. Docker and
    Simulators are `trashIsUnsafe`: Add to Cleanup is replaced by the command,
    and the cleanup queue warns if such a path is staged from any other screen
    (Biggest Files can surface Docker.raw). Docker Desktop data gets a rule, so
    the biggest file on most dev Macs now appears in Developer Storage at all.
  - TASK-056: last source change skips `.git` and every dependency/build
    folder, so a fresh `npm install` doesn't make an abandoned project look
    active. Headline: "N projects untouched for 6+ months hold X".
  - **Safety bug found on the real scan and fixed:** the original catalog
    offered 11 folders *inside app bundles* as "reclaimable, safe" —
    node_modules inside ChatGPT/Cursor updates staged under ~/Library/Caches.
    Hits with an `.app` path component are now never offered.
  - Also fixed: installed Python libraries (`site-packages`) listed as the
    user's projects (225 stray `__pycache__` items → 50); every project path
    showed a bogus "~" prefix; item paths used the scan root as "~".
  - Catalog cost on the real home: ~1.0 s (was 0.9–1.1 s before v2), lazily
    built when the screen opens. 183 tests green, incl. 14 `DeveloperV2Tests`
    and 18 git/gitignore tests.

## Milestone 12 — CLI and export

- [x] **TASK-057: `diskmap` CLI**
  `docs/PRD.md` names this a differentiator and `DiskMapCore` has zero UI
  imports specifically to enable it; `DiskMapScanBench` is a measurement wedge,
  not a product. Ship `diskmap scan --json`, `diskmap dev --reclaimable
  --older-than 6m`, `diskmap dup`, and `diskmap check --fail-over 50GB` with an
  exit-code contract usable as a CI step or pre-commit hook. New
  `executableTarget` depending only on `DiskMapCore`.

- [x] **TASK-058: Export formats**
  JSON, NDJSON, CSV and an `ncdu`-compatible dump, plus "copy paths of
  selection" in the UI. Composable, offline, nearly free.

  **Milestone 12 done 2026-09-28** on `feat/cli`.
  - `diskmap` executable (depends only on `DiskMapCore`): `scan`, `dev`,
    `dup`, `check`, `export`, each with `--json`. Exit codes: 0 ok, 1 `check`
    over threshold, 2 usage error, 3 path unreadable — verified by hand for
    each. Sizes are SI like Finder (`50GB` = 50·10⁹; `GiB` = 1024³); ages
    `30d/2w/6m/1y`. Progress goes to stderr and only on a terminal, so
    `--json` stdout is always one clean document. `ScanEngine`'s summary log
    moved from stdout to stderr for the same reason (it corrupted `--json`).
    Denied folders are reported on stderr, never silently.
  - `TreeExporter` (DiskMapCore) behind both CLI and app: nested JSON, NDJSON,
    RFC 4180 CSV, and ncdu's `-o` format (`[1,1,{meta},[root…]]`, asize =
    logical, dsize = allocated, `ino`/`hlnkc` for hard links). ncdu output is
    always the whole tree because ncdu sums folders itself; `--min-size` /
    `--max-depth` apply to the other formats. Paths are carried down the walk,
    never rebuilt per node; per-row `String(format:)` was the NDJSON hot spot
    (18 s → 3.6 s of writing) and is replaced by a day→string cache and a
    no-escape fast path for JSON strings. The ncdu file is structurally
    checked by tests, not yet loaded into a real `ncdu` (not installed here).
  - Home, release, warm (`docs/perf-results/cli-export-home.txt`, 2.25M items):
    scan alone median 10.2 s; export medians json 12.7, ncdu 13.2, csv 16.2,
    ndjson 16.6 s — i.e. 2.5–6.4 s of writing for 175–468 MB of output.
  - App: **File ▸ Export Scan…** (⇧⌘E; disabled until a scan exists — checked
    in the running app's menu) with a format popup in the save panel, written
    off the main thread, toast on completion. Writes straight to the chosen
    file (the panel already confirmed any overwrite) — no temp-and-delete, so
    the queue stays the app's only removal path.
  - App: **Copy Paths** in the multi-select toolbar of Duplicates, Large Media
    and Old Downloads — one path per line, shell-quoted only when needed;
    a test round-trips spaces, quotes, `$`, backticks and emoji through `sh`.
  - Found on the way: the scan root had no modified date (the walk read dates
    from each parent's bulk records, and the root has none). It now comes from
    the root `lstat` the walk already did for the device id — no new syscall.
  - Tests: `TreeExportTests` (8), `ExportAndCopyTests` (4). 195 tests green.

## Milestone 13 — Find consolidation

- [x] **TASK-059: Query language in ⌘K**
  `ext:mp4 size>500mb age>1y path:~/Downloads`, `name:*.log size>100mb`. Every
  field is already in `FileTree`. Extends the existing `CommandPalette.swift`.

- [x] **TASK-060: One Find surface**
  Fourteen destinations, of which eight are ranked lists of files differing by
  filter and sort, not by concept — parity-shaped IA that mirrors DiskBuddy's
  menu rather than a user's task. Replace with one Find surface plus filter
  chips (Large · Old · Duplicated · Cached · Media · Downloads) over a shared
  list component, with TASK-059's query box for the rest.
  **Ship alongside the existing nav first and measure which chips get used
  before deleting screens.** Highest-leverage UX change in the roadmap and the
  most disruptive: own branch, own `docs/ARCHITECTURE.md` decision-log entry.

  **Milestone 13 done 2026-09-29** on `feat/find`.
  - `FileQuery` (DiskMapCore): `ext: name: kind: size>/< age>/< path: in:
    is: type:`, bare words, `-word`, quoted values. Bad values are reported
    per token and left out, so a half-typed `size>` never empties results;
    unknown `key:` text stays an ordinary word (`10:30`). Size/age/ext/kind
    imply files, because folder totals nest (`type:folder` asks for folders).
    Matched bytes never count a folder inside a matched folder twice.
  - Speed without paths: name tests once per distinct name, on raw UTF-8
    for ASCII (String fallback otherwise — results identical), a literal
    prefilter before `fnmatch`, places as one forward pass over parent links,
    top-N by heap. Real home (2.25M nodes, frozen snapshot, release, machine
    swapping heavily): size/age/place/folder queries 6–27 ms; name queries
    32–77 ms; `name:*.log` 72 ms (was 765); worst seen `name:*e?d*`, 182k
    matches, 327 ms. `docs/perf-results/find-query-home.txt`.
  - Verified identical to a naive evaluator that builds every path, on 7
    queries over the real home tree, and again after each speed-up (byte
    path vs String path, including `café` and a 1.39M-match query).
  - ⌘K: a query shows its meaning, top 8 hits with sizes, and "Show all in
    Find"; plain words now search names via the same engine instead of
    building a path per node per keystroke. `diskmap find <path> <query>`
    exposes it on the command line (`--sort`, `--limit`, `--json`).
    `DiskMapScanBench --from-snapshot F --query Q` times it.
  - Find screen (new first item under Find): query box, sort, and chips
    Large (`size>500MB`) · Old (`age>1y`) · Duplicated (`is:duplicate`) ·
    Cached (`in:caches`) · Media (`kind:media`) · Downloads (`in:downloads`).
    A chip only toggles its token in the text. Multi-select → Add to Cleanup
    / Reveal / Copy Paths; context menu Reveal, Quick Look, Show in
    Visualize, Copy Path. `is:duplicate` explains itself and links to
    Duplicates until that search has run.
  - Shipped **alongside** the existing screens; none removed. Chip use is
    counted in local preferences only (`FindChipUses`) — the measurement the
    ticket asks for, without telemetry.
  - Checked visually with the snapshot harness (`--find-query`), light and
    dark. The ⌘K query mode builds and is covered by the engine tests but
    was not captured by the harness (it cannot open the palette).

## Milestone 14 — Incremental rescan

- [x] **TASK-061: FSEvents-backed incremental scan**
  Rescanning an unchanged home from scratch is pure waste, and rescanning is
  the common case for anyone who opens the app twice. Spec §40 calls for it.
  Persist the `FileTree` (the snapshot codec exists) plus the FSEvents stream
  ID; on relaunch replay events since that ID, mark touched directories dirty
  and re-walk only those subtrees. The 10 s → 200 ms change; makes TASK-056 and
  TASK-064 cheap instead of expensive.
  Most design work of any ticket here: event coalescing, mandatory full-walk
  fallback on `kFSEventStreamEventFlagMustScanSubDirs`, and periodic validation
  that the persisted tree still matches the volume — the spec is explicit that
  a notification system must never be assumed complete. Own milestone.

  **Milestone 14 done 2026-09-29** on `feat/incremental`.
  - Every full scan records the FSEvents id read *before* the walk and the
    volume's FSEvents UUID, and saves tree + baseline to
    `~/Library/Application Support/DiskMap/ScanCache` — one overwritten slot
    per client (`app`, `cli`), so disk use is bounded (~150 MB for a 2.25M-node
    home) and nothing ever needs deleting. Written in the background, tree
    before baseline, both atomic.
  - Rescan replays events since that id, re-lists only the reported folders
    **and their parents** (a folder's own dates/sizes come from its parent's
    listing), walks new folders and "must scan subdirs" subtrees with the
    normal engine, and copies everything else. The copy keeps `parent[i] < i`
    and drops deleted entries, so consumers can't tell it from a walk.
  - Falls back to a full walk, saying why, on: no baseline, changed volume
    UUID, event ids wrapped, root moved, replay timeout, >20 000 changed
    folders, 20 quick updates in a row, a full walk older than 7 days, a
    "/" scan (firmlink twins), or a **spot check** — the root plus 64 random
    unchanged folders re-read and compared — that disagrees with the tree.
  - Measured, not assumed: change events get their id ~0.1 s after the
    syscall, so a replay right after a change missed it (`FlushSync` did not
    help; 1 of 5 trials saw it). Fixed with an ordering barrier: touch a
    marker in the cache folder and wait for its event (~12 ms); FIFO delivery
    means every earlier change is then in the history. 8/8 afterwards, and the
    test that exposed it (a permission change) passes repeatedly.
  - Found on the way: the first name interned into a tree *decoded from a
    snapshot* looped forever (intern table rebuilt at 1 024 slots for
    ~685k names). Latent until now; fixed, with a test that hangs on the old
    code.
  - Correct on real data: an update of the real home diffed against a full
    walk run immediately after differed in 71 of 2.22M nodes — every one a
    log/SQLite/LevelDB file written, or a WhatsApp temp file deleted, during
    that 10 s walk. Fixture tests compare every node field against a fresh
    walk after creates, growth, deletes, moves and new subtrees.
  - Speed (real home, release, machine swapping): full walk 8.0 s; quick
    update from the in-memory tree (the app's Rescan) min 0.21 / median 0.25
    / max 0.80 s; from the disk cache (relaunch, `diskmap --incremental`)
    ~0.75 s of which 0.45 s is reading the cache. `DiskMapScanBench
    --incremental N`; `docs/perf-results/incremental-home*.txt`.
  - App: Rescan is quick by default ("Checking what changed…"); right-click
    Rescan or ⌘K "Full rescan" walks everything. Overview says which it was
    ("Updated from your last scan in 0.3 s — 6 changed folders re-read,
    unchanged ones spot-checked. Full Rescan") or why a full walk was needed.
    Unreadable folders carry across updates until they become readable.
  - CLI: `--incremental` on any command.
  - Not done: a live watcher (the ticket asks for replay on relaunch; a
    running stream would also mean background activity the app promises not
    to do without consent — TASK-064 can decide).

## Milestone 15 — Native affordances

- [x] **TASK-062: Keyboard**
  Six `keyboardShortcut` call sites today. Add `⌘1`–`⌘9` destinations, `⌘R`
  rescan, `↑↓`/`jk` row navigation in every list, `Space` Quick Look, `⌘↓`/`⌘↑`
  drill (currently File Browser only — make it global), `⌘⌫` stage, `⇧⌘⌫` open
  queue, `Enter` reveal in Finder.

- [x] **TASK-063: Drag a folder onto the window or Dock icon**
  Zero `onDrop` / `NSItemProvider` in the codebase; the README already promises
  "Finder-drag-to-scan".

- [x] **TASK-064: Menu bar extra**
  Free space, delta since last scan, one-click rescan — the hook that turns
  DiskMap from a thing you remember when the disk is full into one that warns
  you first. Pairs with TASK-056 and TASK-061. Strictly passive: no
  notifications by default, no background scanning without consent.

  **Milestone 15 done 2026-09-29** on `feat/native`.
  - TASK-062: one `listKeyboard` modifier on all twelve ranked lists (↑↓ /
    j k, Space Quick Look, Return reveal — File Browser opens folders — and
    ⌘⌫ stage, which each list routes through its own staging so the safety
    rules are unchanged; Developer Storage refuses for recipe-only items).
    Menu commands: Go ▸ ⌘1–⌘9 (sidebar order) and ⌘↑/⌘↓, File ▸ ⌘R / ⇧⌘R /
    ⇧⌘⌫. The cleanup sheet moved onto the model so a menu can open it.
    Verified in the running app: the menus list every shortcut (dumped from
    `NSApp.mainMenu`), and synthetic key events sent to the window moved the
    Biggest Files selection by exactly three rows (`--click`/`--keys` in the
    snapshot harness). Rows that select via tap gestures (File Browser, Find)
    don't respond to synthetic clicks even without the modifier, so their
    Return/open path is covered by review, not by that harness run.
  - TASK-063: drop a folder on the window (dashed highlight while dragging;
    files and `.app` bundles are refused with a hint), on the Dock icon, or
    `open -a DiskMap <folder>`. The `.app` declares folders with
    `LSHandlerRank None`, so DiskMap never becomes the default folder opener.
    Verified by opening a folder through the ad-hoc–built `.app`.
  - **Found on the way:** a packaged `.app` never used its own resources.
    SwiftPM's `Bundle.module` only looks at the bundle root and then the
    absolute build path, so the app read its JSON rules from `.build/` —
    hanging on a Downloads-access prompt when launched from Finder (the repo
    lives in ~/Downloads), and it would crash on any other Mac.
    `DiskMapResources` now looks in `Contents/Resources` first.
  - TASK-064: menu bar extra — free space (label turns into "24 GB free"
    with a warning icon under 10%), change since the last scan (±50 MB is
    "about the same"), the last scan's folder/size/age, stale-project line
    when Developer Storage has been built, one-click quick Rescan, Open
    DiskMap, and Hide (DiskMap ▸ Show in Menu Bar brings it back). Passive:
    it scans only when clicked, never notifies; its only periodic work is
    one statfs every five minutes. A `TimelineView` label spun SwiftUI's
    menu bar controller in an endless update loop at launch (found by
    sampling a hung launch) — replaced with a timer-backed observable that
    publishes only on change. The last-scan record is written only by the
    app's own model, never by tests.
  - Tests: `NativeAffordanceTests` (6). 233 tests green.

## Milestone 16 — UX pass from review (2026-09-29)

- [x] **TASK-070: Mind map says what it shows**
  Found: it inherited Visualize's depth slider, which at default folded
  everything under ~2.4% into "Other" (four top-level folders shown for a
  280 GB home); "N more branches" counted the lumped Other as one branch
  (Library: "2 more", really 39 items / 6.7 GB); the centre total was a sum
  of slices; connector stubs on the second row joined nothing. Now: its own
  0.5% threshold, the folder's real total and item count, each branch's
  share, "+N more · X GB — open", a listable "N smaller items" card, and
  connectors routed from the cards' measured frames.
- [x] **TASK-071: Snapshot compare that explains itself**
  Found: the flat diff repeated one change at every ancestor (five changes
  filled the top 15 rows on a real home), took 52 s (debug) and ran on the
  main thread, freezing the window. Now `SnapshotComparison` aligns the
  trees lazily by name (4.2 s to set up, 0.3 ms per level, 41 ms for
  hotspots on the same snapshots), off the main thread, automatically when
  both sides are picked. Page: net change with before/after bars, grew /
  freed split, Mac free-space change, a story built from the hotspots, "What
  changed most" (where each change happened; spread changes stay one row),
  and a breadcrumb drill-down whose rows add up to their folder. Also fixed:
  automatic names said "Today — …" forever.
- [x] **TASK-072: Short windows scroll**
  Found with scroll events sent to the window: screens with a fixed header
  over an inner list gave the list 56 pt (Safe to Review) or nothing
  (Caches) at 600 pt tall, with no page scroll. Below 720 pt those screens
  now scroll as a page. (Both sidebars already scrolled; the earlier harness
  scroll tool was sending screen coordinates — fixed.)
- [x] **TASK-073: Appearance control**
  System / Light / Dark from a top-bar button or View ▸ Appearance, stored
  and applied app-wide at launch. Verified: Light on a dark system renders
  light.
- [x] **TASK-074: Select several things**
  ⌘-click adds/removes, ⇧-click takes a range, plain click resets — in every
  Visualize chart, Biggest Files and Biggest Folders — with a toolbar
  (count, bytes counting a folder and its contents once, Add to Cleanup,
  Reveal, Copy Paths, Clear). ⌘A / Esc select all / clear in every
  checkbox list. Modifiers are read from the keys held, because SwiftUI runs
  button actions after the click event (measured). Verified with ⌘-clicks
  in Biggest Files and the mind map; tap-gesture charts (treemap) ignore
  synthetic clicks, so there only the shared code path is tested.
  243 tests green.

## Milestone 17 — Follow-ups from the post-UX review (2026-10-03)

Twelve tickets, planned in order 075 → 076 → 078 → 077 → 082 → 079 → 080
→ 081 → 085 → 086 → 084 → 083. Everything stays local (no push).

- [x] **TASK-075: Integrate PR #16 and the Windows port locally**
  Branch `integrate/pr16-windows` off `feat/ux-pass`, two `--no-ff` merges.
  PR #16 (`origin/main`): conflicts in 11 files resolved toward the
  AppDestination/AppShellView structure. Kept side by side: **Search**
  (`FileSearchIndex`, Find section after Find) and **Regenerable Data**
  (categorized Quick Wins, Explore section after Developer Storage), both
  with page headers, the shared list keyboard, harness entries and short-
  window scrolling; ⌘1–9 shifted (docs/ACCESSIBILITY.md). Ported: the
  size-colliding duplicate prefilter into our walk (hard-link dedup and
  cancellation kept), categories in `quick-wins-patterns.json` with our
  resource lookup, iCloud icons on not-downloaded rows, the bounded cleanup
  receipt, `scanID`, and a guard that ignores a second scan request for the
  folder already being scanned (test added). `SnapshotDiffView` stays
  removed. Harness fix found on the way: a synthetic click on a text field
  hung, because AppKit's tracking loop waited for a mouse-up the harness
  sent only afterwards; the up is now queued first.
  Windows port (`origin/feat/windows-port`): merged clean (`windows/**` and
  an AGENTS.md section that restates rules 1–3 for Windows). Checked:
  nothing under `windows/` uses networking; the only removal path is
  `SHFileOperation(FOF_ALLOWUNDO)` (Recycle Bin) — `Directory.Delete`
  appears only in tests cleaning their temp fixtures. Added
  `.github/workflows/windows.yml` (windows-latest, .NET 10, `windows/**`
  paths only). Excluded-paths list unchanged. 253 tests green.
  Duplicates bench (`docs/perf-results/integrate-pr16.txt`, ~/Downloads,
  5 alternating runs): candidates 18,013 → 11,218, same 311 groups and 966
  full hashes, median 1.36 s → 1.22 s end to end; the bench now times the
  app's candidate path.
- [x] **TASK-076: Overview makes sense for any scanned folder**
  Found: a scan of `~/Downloads` (or a drive) showed one "Other — 100%"
  row, because categories map the root's children by home-folder names.
  Now `CategoryMode.detect` picks **home** (the user's home, or ≥ 2 of
  Library/Downloads/Documents/Desktop as children), **whole disk** (`/`),
  or **folder** — which splits by file type (the scan's File Types totals,
  passed in on the same basis) plus "Other" for unclaimed files; rows sum
  to the scanned total (hard links counted once — real-fixture test). Card
  title "What's in Downloads?", type colours from
  `file-type-categories.json`; rows are buttons: a type opens Find with
  `kind:<type>`, Other opens Biggest Files, a home folder opens Visualize at
  it. The story names the largest *named* category ("Video is 92% of this
  folder"; "Other" never leads). Also: File Types after a scan were always
  allocated even on the logical basis — now the active basis; shares under
  0.5% read "<1%" instead of "0%". Verified on ~/Downloads (Video 59.96 GB,
  92%; clicking it opens Find with 6,399 matches, 59.96 GB) and on ~
  (unchanged). 259 tests green.
- [x] **TASK-078: Rows and charts reachable by keyboard and VoiceOver**
  Baseline: a harness click on a File Browser row changed nothing (renders
  byte-identical) — tap-gesture rows are invisible to VoiceOver and to
  synthetic clicks. Rows in File Browser, Find, Search, Visualize's table,
  Applications, Large Media and Old Downloads are now a checkbox plus one
  plain select button (labels, selected trait, "Open"/"Reveal in Finder"
  action; double-click kept). Age bar segments are buttons; Age Map rows
  got an action. Treemap, Sunburst, Flame and Bubbles expose their 60
  biggest items as buttons with "name, size, share" and an "Open" action
  for folders (`ChartAccessibility`, 3 tests). New harness flag
  `--dump-ax` writes each screen's accessibility tree from inside the app.
  Verified: File Browser click → selected, Return → opened the folder;
  Find click selects; a treemap tile click selects it (inspector shows the
  file) — the earlier "charts ignore synthetic clicks" was the harness
  mouse-up bug fixed in TASK-075; trees dumped for File Browser, Find,
  Media, Treemap and Sunburst. 262 tests green.
- [x] **TASK-077: Clone-aware totals (measurement-gated → opt-in)**
  Measured first: `AttrProbe --extended [--refcount-only]` gives the record
  layout for BulkScan's mask plus the APFS extended attributes (PRIVATESIZE
  108 · CLONEID 116 · REFCNT 132 · prefix 136; refcount-only: CLONEID 108 ·
  REFCNT 116 · prefix 120 — `docs/perf-results/attr-probe-ext.txt`). Found
  on this Mac's home: 884,689 clone rows (34.8% of nodes), 317,483
  families, **80.1 GB counted more than once**; no refcount>1 member had
  private bytes, so CLONEID + REFCNT is enough for families. The walk reads
  them (`SharingMode` refcount/full, APFS and the root's device only, EINVAL
  falls back to plain) into a sorted side table on `FileTree` (no per-node
  array), sets `apfsClone`, and the allocated rollups charge each family's
  lowest-inode member in full and the others their private bytes;
  `sharingCorrection()` reports families, bytes and edited copies (counted
  in full). Snapshot codec v4 (v1–v3 decode as "unknown"); quick rescans
  carry rows and refuse to mix trees with and without clone facts.
  **Gate:** refcount +14% median / +22% p95 on the walk, full ~1.9×
  (`docs/perf-results/clone-scan-ab.txt`) — over +10%, so it ships as a
  Settings choice (new Settings window, ⌘,), off by default; Overview says
  clones are counted per copy and links to it; with it on, Overview shows
  "715,111 cloned copies in 296,518 groups share 83.09 GB … counted once",
  the file inspector says what a clone shares, `diskmap --clones` does the
  same in the CLI (353.45 → 270.36 GB on ~). ExFAT guarded (optional test on
  the fixture volume). 8 new tests on real `cp -c` clones (family once,
  split across folders with a stable electee, edited clone, hard-linked
  clone, plain files, codec, malformed table, quick rescan). 270 tests green.
- [x] **TASK-082: Instant staging measurement (exact or not at all)**
  `CleanupQueue.setScanContext` after every scan; staging a folder first
  tries `StorageSharing.seededMeasurement` — the folder's subtree from the
  tree (plain files summed, clones built from the sharing table, hard links /
  cloud files / estimated allocations asked one by one; new
  `NodeFlags.allocatedEstimated`), after an FSEvents barrier and replay
  confirm nothing under it changed — and falls back to the walk with a
  reason. Exactness rule: on APFS only after a `.full` scan (the tree now
  records its `sharingMode`; codec v4 stores it), because without
  PRIVATESIZE an edited clone looks plain and its shared blocks would count
  as freed — an overestimate. Rows say "from the scan at 14:02". The walk
  now skips symlinks, as the scan does (it counted them as 0-byte files —
  the only difference the equality test found). Measured
  (`docs/perf-results/seeded-staging.txt`): ~/FreeCAD, 147,226 files,
  0.06–0.14 s from the tree vs 4.6–4.7 s walked, `Profile` equal; ~/Downloads
  0.04 s vs 2.8 s, equal. ~/Library/Caches is written during every scan, so
  it is walked ("2 folders changed since the scan") — correct, not a miss.
  Default settings (clone accounting off) keep the walk everywhere on APFS.
  7 tests (equality on a fixture with plain/empty files, hard links in and
  out, a clone family across the boundary, an edited clone, a symlink;
  change after scan; limit; non-full modes; unreadable subfolder; file /
  unknown path; queue source). 277 tests green.
- [x] **TASK-079: Storage history and "What grew this week"**
  `StorageHistory` (core, Foundation only): after every completed scan the
  app records one entry per root — free/total/scanned bytes, unreadable
  count, the clone accounting used, and folder sizes (root children ≥ 50 MB,
  plus the 20 largest children of any top-level folder ≥ 5 GB or ≥ 5%; cap
  300) — in `~/Library/Application Support/DiskMap/History/<fnv>.json`,
  rewritten atomically, never deleted. Retention: one entry per day (the
  last), every day for 30 days, the last per ISO week for a year, nothing
  older. A damaged file is left alone; `<fnv>.v2.json` takes over.
  Comparison: the entry nearest 7 days back among those ≥ 5 days old, else
  the oldest ≥ 2 days old ("since …"), only between entries counted the
  same way (clones on/off would read as a fake 80 GB shrink); growers ≥
  100 MB, second-level folders only when both scans looked inside the
  parent, a parent dropped when a listed child explains 80% of it; a caveat
  when the unreadable count differs. Overview card (rows open File
  Browser), menu bar line ("Free space −12 GB this week · Library +8 GB"),
  Settings ▸ Keep storage history (default on; off stops writing). Only the
  app's own model writes (`ScanModel()` in tests never does);
  `-StorageHistoryDirectory` points the harness at a scratch folder.
  Verified with a seeded week-old entry for ~/Downloads (render). 10 tests.
  287 tests green.
- [x] **TASK-080: Put Back the last cleanup**
  `moveToTrash` now returns `trashItem`'s resulting URL; `CommitEntry` keeps
  it; `CleanupRecord` (original path, Trash path, bytes) is built from the
  commit report and persisted to `last-cleanup.json`.
  `CleanupQueue.putBack` moves items back only when still in the Trash and
  nothing is at the old path (skips say why), recreating a missing parent;
  then a quick rescan. UI: "Put Back N Items" in the cleanup sheet, File ▸
  Put Back Last Cleanup, toast "Put back N of M", receipt lists skips. Tests
  through the seam with a fake Trash folder (never the real one): restore
  exact paths and sizes, occupied path untouched, emptied Trash reported,
  folder brings its queued child, missing parent recreated, failures not
  recorded, record round trip. No `removeItem` in app or core code; the
  only new file operation is `moveItem` out of the Trash. 294 tests green.
- [x] **TASK-081: Saved searches in the sidebar**
  `SavedSearch` (id, name, query, sort) kept as JSON in preferences
  (`SavedSearches`, max 20; only the app's own model writes). Find has
  Save… (⌘S) with a name from the query's meaning; the sidebar shows a
  "Saved" section under Find — outside the numbered list, so ⌘1–⌘9 do not
  move — with each search's live size (one count-only `FileQuery` pass per
  search after every scan and on change, off the main thread), selected
  while Find shows that query; Rename / Move Up / Move Down / Remove from
  Sidebar (removes the search, never files). ⌘K lists them. Find's empty
  state offers three starters (Old installers, Big videos, Logs), never
  added on their own. Harness `--saved-searches '<json>'` (memory only).
  Verified: render with two saved searches — "Big videos 42.42 GB", equal
  to Find's total for the same query. 5 tests. 299 tests green.
- [x] **TASK-085: Text size, chart keyboard, VoiceOver row actions**
  `TextSize` (0.9 / 1.0 / 1.15 / 1.3) drives every `DiskMapType` token,
  87 literal point sizes and 27 system text styles, and the sidebar width;
  View ▸ Text Size with ⌘+ ⌘− ⌘0 and a Settings picker; the window rebuilds
  on change. All destinations rendered at Largest. Charts are focusable:
  treemap arrows by geometry, radial/stacked charts by sibling/parent/child
  (`ChartNavigation`, core, tested), Return / ⌘↑ / Space / ⌘Space. Shared
  `.rowActions` gives seven lists Add to Cleanup / Reveal / Quick Look for
  VoiceOver. Harness: picks the real window (it rendered the menu bar
  status item once) and waits for it; arrow keys; note that `-Key value`
  defaults must come before valueless flags, or the value is taken as a
  document to open and SwiftUI opens no window. 303 tests green.
- [x] **TASK-086: Scan time consistency (p95) — investigated, closed**
  Baseline (sequential, 20 runs): median 15.52 s, p95 24.06 s (1.55×).
  The prime suspect — fixed 1M/400k reservation against a 2.68M-node,
  950k-name home — was tested with a capacity hint from the last scan in
  12 alternating pairs: no improvement (paired median 1.07×, p95 worse),
  so it was reverted rather than shipped. The tail tracked outside load
  (load average 6.5–10, a Docker VM at 0–100% CPU run to run). Evidence:
  `docs/perf-results/p95-walk-tail.txt`; PERF.md updated with the
  method lesson (alternate A/B, quiet machine).
