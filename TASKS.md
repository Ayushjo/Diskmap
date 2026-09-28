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

- [ ] **TASK-043: Lazy catalogs**
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

- [ ] **TASK-044: Streaming first paint**
  Publish a tree snapshot every ~400 ms during the walk with partial rollups so
  the treemap and Overview grow while scanning. Largest perceived-speed win
  available; needs no engine speedup. Must respect the existing
  `scanGeneration` cancellation guard.

- [ ] **TASK-045: Remove confirmed waste in BulkScan**
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

- [ ] **TASK-046: Progress that means something, and a p95 goal**
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

## Milestone 10 — Dark mode

~100 hardcoded colour call sites across 22 files plus 18 tokens. There are zero
`Color(nsColor:)` and zero `@Environment(\.colorScheme)` uses — nothing reads
the ambient appearance. Do this before more views exist to retrofit.

- [ ] **TASK-047: Consolidate the duplicated palettes first**
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

- [ ] **TASK-048: Semantic tokens with light and dark values**
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

- [ ] **TASK-049: Re-tune the visualization palettes, don't just re-tint**
  `ExploreColoring` encodes two cues that **invert** on dark: `.folder` fades
  descendants by opacity (reads lighter on cream, darker on near-black — the
  depth cue reverses), and `.age` uses HSB brightness 0.55–0.80 with the oldest
  bucket darkest. The `.type` palette comes from
  `Sources/DiskMapCore/file-type-categories.json` — the one palette themeable
  without touching Swift, via a second colour field in the schema.

- [ ] **TASK-050: Type scale adoption**
  606 `.font(.system(size:` call sites across 27 files; `DiskMapType` is used
  only 99 times — 86% bypass the scale. Sizes cluster at 11/12/13 (405 of 606)
  and there is no 12 pt token, which likely explains 184 hand-rolled sites. Add
  one, adopt the scale, and the Dynamic Type pass listed as "still open" in
  `docs/ACCESSIBILITY.md` becomes tractable instead of a 606-site edit.

## Milestone 11 — Developer Storage v2

`DeveloperCatalog` matches directory **names** today — right skeleton, wrong
unit of analysis. All of this runs on the existing `FileTree` + totals from one
walk; no second disk pass, no network.

- [ ] **TASK-051: Project roots by manifest**
  `projectFromParent: true` calls the parent of `node_modules` the project,
  which is wrong for monorepos, pnpm workspaces and nested packages. Walk up to
  the nearest `package.json`, `Cargo.toml`, `go.mod`, `pyproject.toml`,
  `Package.swift`, `*.xcodeproj`, `pubspec.yaml`, `pom.xml`. Prerequisite for
  everything below.

- [ ] **TASK-052: Rebuild cost as a first-class column**
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

- [ ] **TASK-053: Git state of the owning repo**
  Read `.git/HEAD`, `.git/refs/`, `.git/config` directly — no subprocess, no
  network. Derive: is this a repo, is there an `origin`, are there local refs
  absent from `refs/remotes/origin/`. Lets the app distinguish "pushed to
  origin, fully recoverable" from "unpushed commits, do not delete". Handle
  worktrees and `.git`-as-a-file; degrade to "unknown" rather than guess.

- [ ] **TASK-054: `.gitignore` as a reclaimability oracle**
  Anything git ignores is, by the repo author's own declaration, regenerable
  and untracked — a stronger signal than our hardcoded name list, and it covers
  ecosystems we have no rule for. Start **read-only** (report ignored bytes per
  repo); staging from it is a separate later decision.

- [ ] **TASK-055: Tool-native cleanup recipes**
  Some of the biggest developer directories are actively wrong to Trash:
  `Docker.raw` is a single sparse disk image whose deletion destroys every
  image, volume and container at once; `CoreSimulator` folders are tracked in
  `simctl`'s own database and deleting underneath it corrupts that state.
  For these, replace "Add to Cleanup" with the real command
  (`docker system prune -a`, `xcrun simctl delete unavailable`, `brew cleanup`,
  `npm cache clean --force`, `pnpm store prune`, `go clean -modcache`), a Copy
  button, and one line on why we are not doing it for you. **Show, never run** —
  this honours the single-deletion-path rule rather than straining against it.

- [ ] **TASK-056: Project ageing**
  Max `modifiedDay` over a project **excluding** its reclaimable subtrees = when
  a human last worked on it. Unlocks "23 projects untouched for 6+ months are
  holding 41 GB of dependencies" — the headline that makes people open the app.

## Milestone 12 — CLI and export

- [ ] **TASK-057: `diskmap` CLI**
  `docs/PRD.md` names this a differentiator and `DiskMapCore` has zero UI
  imports specifically to enable it; `DiskMapScanBench` is a measurement wedge,
  not a product. Ship `diskmap scan --json`, `diskmap dev --reclaimable
  --older-than 6m`, `diskmap dup`, and `diskmap check --fail-over 50GB` with an
  exit-code contract usable as a CI step or pre-commit hook. New
  `executableTarget` depending only on `DiskMapCore`.

- [ ] **TASK-058: Export formats**
  JSON, NDJSON, CSV and an `ncdu`-compatible dump, plus "copy paths of
  selection" in the UI. Composable, offline, nearly free.

## Milestone 13 — Find consolidation

- [ ] **TASK-059: Query language in ⌘K**
  `ext:mp4 size>500mb age>1y path:~/Downloads`, `name:*.log size>100mb`. Every
  field is already in `FileTree`. Extends the existing `CommandPalette.swift`.

- [ ] **TASK-060: One Find surface**
  Fourteen destinations, of which eight are ranked lists of files differing by
  filter and sort, not by concept — parity-shaped IA that mirrors DiskBuddy's
  menu rather than a user's task. Replace with one Find surface plus filter
  chips (Large · Old · Duplicated · Cached · Media · Downloads) over a shared
  list component, with TASK-059's query box for the rest.
  **Ship alongside the existing nav first and measure which chips get used
  before deleting screens.** Highest-leverage UX change in the roadmap and the
  most disruptive: own branch, own `docs/ARCHITECTURE.md` decision-log entry.

## Milestone 14 — Incremental rescan

- [ ] **TASK-061: FSEvents-backed incremental scan**
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

## Milestone 15 — Native affordances

- [ ] **TASK-062: Keyboard**
  Six `keyboardShortcut` call sites today. Add `⌘1`–`⌘9` destinations, `⌘R`
  rescan, `↑↓`/`jk` row navigation in every list, `Space` Quick Look, `⌘↓`/`⌘↑`
  drill (currently File Browser only — make it global), `⌘⌫` stage, `⇧⌘⌫` open
  queue, `Enter` reveal in Finder.

- [ ] **TASK-063: Drag a folder onto the window or Dock icon**
  Zero `onDrop` / `NSItemProvider` in the codebase; the README already promises
  "Finder-drag-to-scan".

- [ ] **TASK-064: Menu bar extra**
  Free space, delta since last scan, one-click rescan — the hook that turns
  DiskMap from a thing you remember when the disk is full into one that warns
  you first. Pairs with TASK-056 and TASK-061. Strictly passive: no
  notifications by default, no background scanning without consent.
