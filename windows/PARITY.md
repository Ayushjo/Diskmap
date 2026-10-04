# Windows Port — Feature Parity Tracker

What the macOS app has that the Windows port doesn't yet, as checkable tickets
with the macOS source reference and the intended Windows home for each piece.
The macOS side's source of truth is `TASKS.md` (everything checked off there is
a parity candidate); this file is the Windows side's equivalent.

Status legend: `[ ]` open · `[x]` done · `[~]` partial — note what's missing in
the item body. Keep items in priority order within each section; P0 items are
correctness gaps (wrong numbers), P1 is user-facing parity, P2 is polish and
differentiators.

Non-negotiables that apply to every ticket below (restated from AGENTS.md):
- All deletion routes through `CleanupQueue.Commit()` →
  `SHFileOperation(FOF_ALLOWUNDO)`. Never add a second removal path.
- No networking, anywhere.
- The excluded-paths list in `src/DiskMap.Core/CleanupQueue.cs` is the last
  line of defense — changes get called out explicitly in the change summary.
- Run `dotnet test windows\DiskMap.Win.slnx` after every change.

---

## 0. Already at parity (reference — don't re-open)

- [x] Fast scan: `$MFT` raw parse (elevated, parallel chunk reads) +
  `FindFirstFileExW` work-queue fallback with fallback-reason reporting.
  Counterpart of the `getattrlistbulk` walk; ~9 s for 8M items elevated.
- [x] `FileTree` struct-of-arrays + interned names, `Compact()`,
  `RollUpSizes(basis)`, `PathOf`, `ChildrenOf`, `AncestorIds`.
- [x] Cloud placeholders (OneDrive `OFFLINE`/`RECALL_ON_*`): recorded with
  `NodeFlags.NotDownloaded`, descendants skipped, never opened.
- [x] Reparse points (symlinks/junctions) skipped — the `O_NOFOLLOW` rule.
- [x] Squarified treemap, Sunburst, Flame, Bubbles, Mind Map controls, each
  with drill-down and an "Other" collapse (`ChartLayout.OtherFraction`).
- [x] Logical / On Disk size toggle shared across all pages.
- [x] Breadcrumb bar + drill-to-ancestor.
- [x] Top Sizes (ranked, capped), Folders, Age Map (buckets + "untouched
  over a year" + staging) pages.
- [x] Duplicates: size → 64 KB partial SHA256 → full SHA256, clone-skip via
  `FSCTL_GET_RETRIEVAL_POINTERS` extent maps, keep-oldest default,
  shared-extent reclaim math (`ReclaimableBytes`).
- [x] Quick Wins: categorized `quick-wins-patterns.json`, grouped display,
  staged via queue.
- [x] Apps: registry Uninstall hives + heuristic leftovers
  (`%APPDATA%`/`%LOCALAPPDATA%`/`%PROGRAMDATA%`), staged via queue.
- [x] Snapshots: `DMAP` v1 codec (read/write), store, header-only listing,
  flat path-matched folder diff.
- [x] Cleanup queue: grouped by reason, shared-group reclaim rule, excluded
  prefixes, Recycle-Bin-only commit, per-item success/failure results.
- [x] Reveal in Explorer (`explorer /select`).
- [x] `ProcessMemory` working-set reporting; scan summary log.
- [x] CI: `.github/workflows/windows.yml`.
- [x] MFT-path hard links: first name charged, later names read 0 with
  `NodeFlags.HardLink` (macOS "charge once" rule — MFT path only, see
  WIN-002).

---

## 1. Scanning & tree model — P0

- [x] **WIN-001: File identity in `FileTree` — file index + link count**
  macOS: TASK-036 (`fileID: [UInt64]` array, `hardLink` flag, +8 B/node).
  Windows: `FileId` (`long[]`) + `CreatedDay` (`int[]`) on `FileTree`,
  `AddNode` defaults, packed-array `ReplacePacked`, DMAP v4 codec
  (win-067). Both scanners populate them: the walk via
  `NtQueryDirectoryFile(FileIdBothDirectoryInformation)` — file id +
  creation time + real AllocationSize inline, no per-file call — and the
  MFT path via record number + `$STANDARD_INFORMATION` created time. The
  MFT path flags multiply-named records `HardLink` (names living outside
  the scan included, like macOS's link count); the walk flags file-id
  repeats — links outside the scan aren't visible there, which only
  changes the flag, never the accounting.

- [x] **WIN-002: Hard-link-aware rollups in the walk backend**
  macOS: TASK-037 (suppress duplicates inside `ownSize`; election by lowest
  path, not node id, for snapshot-diff stability; group-of-one outside the
  root keeps full size).
  Done: `FileTree.RollUpSizes`/`RollUpBoth`/`ownSize` suppress every
  flagged name but the lowest root-relative path — the macOS rule, now on
  both backends (the MFT path no longer zeroes late names at insert: all
  names keep recorded sizes, suppression happens at rollup so per-node
  sizes stay true). `GetHardLinkCorrection()` reports the suppressed
  bytes/names as a named figure. Tests: real `CreateHardLinkW` fixture
  (`HardLinkedNamesShareFileIdAndChargeOnce`,
  `ElectedHardLinkNameIsTheLowestPath`,
  `UnrelatedFilesWithDistinctIdsBothCharge`).

- [x] **WIN-003: Report unreadable/denied directories**
  macOS: TASK-039 (`deniedDirectoryIDs` via `errno`, EACCES/EPERM surfaced
  vs ENOENT mid-scan deletion vs ELOOP; banner + example paths in Overview).
  Done: `NtQueryDirectoryFile`/`CreateFileW` failing with
  `ACCESS_DENIED` records the node id into `DeniedDirectoryIds` (other
  failures — raced deletes — counted, not listed), carried
  `WalkResult`→`ScanEngine.Result`→`ScanModel`, and the Overview page
  shows a warning card with count + example paths. Test:
  `DeniedDirectoryIsReportedByNodeId` (real deny ACL on a fixture dir).

- [x] **WIN-004: Scan cancellation + termination audit**
  macOS: TASK-065 (dropped-subtree race — `publishing` counter in the
  termination condition), TASK-066 (thread-pool starvation deadlock),
  `scanGeneration` cancellation guard.
  Done: `ScanEngine.ScanAsync`/`Win32Scanner.Walk`/`MftScanner.Walk` take
  a `CancellationToken`; a cancelled scan publishes no partial tree
  (`ScanModel` keeps the last finished one); the top-bar Rescan button
  becomes Cancel while a scan runs. The audit found and fixed a real
  termination bug (inflight was only decremented, so the queue could
  never reach its finished state) — now counted enqueue→publish, the
  dequeued-but-unpublished shape from TASK-065. Tests:
  `CancelledWalkThrowsAndPublishesNothing`,
  `ConcurrentWalksAllTerminate`.

- [x] **WIN-005: Volume stats + scan reconciliation**
  macOS: TASK-040 (`statfs` used vs scanned bytes, `unaccountedBytes`,
  "this scan accounts for X of the Y in use", honest copy listing causes:
  other volumes, VSS/restore points, unreadable folders; never inflate a
  category to close the gap).
  Done: `AnalysisSnapshot.Reconciliation` (used vs scanned-on-disk,
  unaccounted, coverage fraction, exceeds-used flag) + the Overview
  health card's "this scan accounts for X of the Y in use" line naming
  the Windows causes (restore points/system state, mounted volumes,
  unreadable folders, MFT metadata). The hard-link correction is shown
  as its own line too — counted-once blocks explained, not hidden.

- [x] **WIN-006: Streaming scan progress**
  macOS: TASK-044 — publisher keeps running per-top-level totals (each
  job carries its top-level ancestor, O(1) attribution), emits a
  `ScanProgress` every 250 ms: items, bytes, items/s, current folder,
  largest top-level folders.
  `ScanProgress(items, bytes, items/s, currentFolder, topLevel)` reports
  every 250 ms from both backends — walk jobs carry their top-level node
  id, the MFT build attributes each node to its root child. The banner
  shows folder/items/rate/bytes plus per-top-level fill bars for the
  six biggest roots (data straight from the report).

- [x] **WIN-007: Phase indicator + post-walk narration**
  macOS: TASK-046 — headline follows the real phase (walking →
  "Summarizing…"), not item-count thresholds.
  Done: `ScanModel.ScanPhase` (`walking`/`summarizing`) drives the strip
  text — items/s during the walk, "Summarizing — rolling up sizes…"
  during the rollup pass.

- [x] **WIN-008: `rollUpDescendantCounts`**
  macOS: post-scan iterative pass giving every directory its item count —
  drives "N items" labels, the mind map's real totals, and several
  inspector lines. Done: `FileTree.RollUpCounts()` — one reverse pass
  giving every node (files, folders) descendant counts; `ScanModel.Counts`
  computes it after each scan.

---

## 2. Cleanup correctness — P0

- [x] **WIN-009: True reclaim math inside `CleanupQueue`**
  macOS: TASK-038 — `stage()` itself measures sharing (dev/ino/nlink per
  staged path; hard-link inode charged once only when every name staged;
  clone families via sharing profile; items inside a staged folder counted
  once via the folder). No call site can get it wrong.
  `StorageSharing.ProfileAt` measures
  each staged path off-thread (single-file = one open; folder = a
  `NtQueryDirectoryFile` walk + `GetFileInformationByHandle` per file for
  the authoritative link count — a name linked outside the staged set
  can't pretend to be the last one). `Estimate()` ports the macOS math:
  covered-by-a-staged-folder dedup, multiply-linked inode charged once
  when staged names reach `nNumberOfLinks` (else `HeldByUnqueuedCopies`),
  unreadable paths fall back to the caller's size/group hint with
  `IsLowerBound`. ReFS block clones have no refcount API on Windows, so
  extent sharing is deliberately *not* treated as reclaimable — counting
  it could overclaim against an unstaged third clone. Hard links are the
  measurable sharing class here. Tests: `HardLinkedNamesFreeOnceOnlyWhenAllStaged`,
  `StagedFolderCoversStagedChildren`, hint-group fallback.

- [x] **WIN-010: Honest commit receipt + folder-first commit ordering**
  macOS: TASK-038 — receipt recomputed over successes; "freed when you
  empty the Recycle Bin"; "at least" wording when shared blocks can't be
  attributed; children of a committed folder report "moved with its
  folder" instead of retrying as failures; bounded report view.
  Done: `Commit()` returns a `CommitReport` — entries carry
  `MovedWithFolder` + per-item `FreedBytes`; `FreedWhenEmptied` is
  recomputed over the succeeded subset only and the dialog says "at
  least" when the estimate is a lower bound. Ordering is path-depth then
  ordinal. Tests: `CommitRecyclesFoldersBeforeTheirStagedChildren`,
  `CommitReceiptCountsOnlyWhatActuallyMoved`.

- [x] **WIN-011: Non-blocking staged-folder measurement**
  macOS: staging a folder measures its real size in the background
  (single-threaded walk; `isCalculating`; commit disabled until known).
  Done: `Stage` returns immediately; `StorageSharing.ProfileAt` walks the
  folder on a background task honoring the same reparse/cloud rules as
  the scan (`Decide`). `Estimate().IsCalculating` while any item measures;
  the Cleanup page disables the commit button and shows "measuring…"
  until it settles (`Cleanup.Measured` → refresh).

- [x] **WIN-012: Put Back last cleanup**
  Done via option (b): `CleanupRecord` at `%LOCALAPPDATA%\DiskMap\
  last-cleanup.json` (atomic rewrite, survives relaunch); after commit,
  `RecycleBinStore` parses `$I*` metadata under `<drive>:\$Recycle.Bin\
  <SID>` (v1 + v2 layouts) to resolve each moved item's `$R` payload.
  `PutBack.Run` moves it back (File/Directory.Move — a restore, never a
  delete), recreates missing parents, skips occupied paths and emptied
  items with reasons, and removes the `$I` sidecar. The Cleanup page
  shows an "Undo the last cleanup" card with the date/count/bytes; the
  test exercises the real bin end-to-end.
  Prototype (a) first; fall back to (b) with a test against a temp
  "recycle bin" seam, never the real one (mirror `PutBackTests`).

- [x] **WIN-013: Seeded (instant) staging measurement**
  `CleanupQueue.SetScanContext(tree, root, marker, deniedIds)` — called
  by ScanModel after every scan; `TrySeededProfile` descends the staged
  path into the tree, then (a) collects the subtree's file ids and (b)
  reads the USN journal since the scan's marker — any overlap → walk
  fallback; unreadable journal (non-admin) → walk fallback; outside the
  scan root → walk. Seeded profiles still take a real link count per
  hard-linked file (`FactsOfPublic`) and mark IsComplete=false over
  denied subtrees — never exact-claims. `JournalChangesForTest` seams
  the ioctl so the math is exercised unelevated (5 tests: unchanged
  seeds, changed subtree refuses, unreadable journal refuses, outside-
  root refuses, no-context walks).

---

## 3. Core catalogs & queries — P1

All run on the existing `FileTree` + totals from one walk; no second disk
pass. macOS reference files are named per item; all belong under
`src/DiskMap.Core/` with data JSON beside `quick-wins-patterns.json`.

- [x] **WIN-014: `AnalysisSnapshot` + volume stats core type**
  `AnalysisSnapshot.swift`, `VolumeStats.swift` — category totals, volume
  figures, reconciliation (WIN-005), the data behind Overview.
  Done: `AnalysisSnapshot.cs` ports the type — `CategoryMode` detect
  (drive-root → whole-disk, profile-or-lookalike → home, else folder),
  Windows name categorization (AppData with cache/dev peel, Downloads,
  Personal incl. OneDrive, Developer names/dotdirs, System), folder-mode
  by-file-type categories, top files/folders, forgotten/quick-win bytes,
  health, reconciliation. `ScanModel.Snapshot` builds it in the
  summarizing phase and on basis toggles; Overview renders categories
  and the reconciliation.

- [x] **WIN-015: `FileTypeCatalog` + `file-type-categories.json`**
  `FileTypes.cs` reads the embedded `file-type-categories.json` (kind
  labels, colors, badge colors, extension sets — extended with the
  Windows extras .vhdx/.exe). Feeds kind badges, the folder-mode
  Overview categories, dominant-kind tile colors and `kind:`/`type:`
  query tokens (`FileQuery.KindExtensions` + the "media" union).

- [x] **WIN-016: `FileQuery` — the Find query language**
  Ported: `ext: name: kind: size>/< age>/< path: in: is: type:`, bare
  words, `-word`, quoted values, per-token problems (a half-typed
  `size>` never empties results), matched-bytes counts a folder inside
  a matched folder once. Same performance shape: name tests once per
  interned name, `in:`/`path:` resolved to ids once then a forward
  parent-link pass, top-N by bounded heap, no path building.
  Windows specifics: `~`→profile, `%VAR%` expansion, `in:` takes
  downloads/desktop/documents/appdata/caches ("library"→AppData),
  `is:` takes duplicate/hardlink/cloud; a hand-rolled glob matcher
  (* ? [set] [!set]) stands in for fnmatch. `HumanUnits` carries the
  50GB/2GiB/30d/2w/6m/1y contract. Tests in `FileQueryTests.cs`.

- [x] **WIN-017: `FileSearchIndex` — find-as-you-type name search**
  `FileSearch.Search`: substring match once per interned name, node
  collection through the tree, ranked by size via `TopSizes.Largest`'s
  bounded heap. Powers the Find page's bare-word fallback.

- [x] **WIN-018: `OldDownloadsCatalog`**
  Old Downloads page: every "Downloads" directory found in the scan,
  ranked files inside, stage via bottom bar.

- [x] **WIN-019: `MediaCatalog` (Large Media)**
  Large Media page: video/audio/image kinds over 100 MB via the JSON
  extension sets, stat cards + type/age breakdown, staged.

- [x] **WIN-020: `ForgottenFiles`**
  `AgeMap.Untouched` (large files untouched >1y, largest-first) +
  Forgotten Files page with stat cards and an age-distribution bar.

- [x] **WIN-021: `ReviewableTargets` + `SafetyClassification`**
  Safe to Review page: reviewable total + per-category cards drilling
  into Caches/Old Downloads/Large Media/Developer Storage; Quick Wins
  supplies the conservative regenerable data and safety badges.

- [x] **WIN-022: `DeveloperCatalog` v2 + `developer-rules.json`**
  `DeveloperCatalog.cs` ports the engine against the embedded
  `developer-rules.json` — Windows-adapted data (dotnet ecosystem
  replaces xcode: bin/obj/publish, .vs, TestResults, packages, .nuget,
  .dotnet; plus Windows.old, `env`/`nvm`/`sdk` plausible-hit guards).
  Rule scan → installed-app-dir skip (Program Files/WindowsApps = the
  .app-bundle counterpart) → outer-folder preference → ProjectLocator
  (nearest manifest, stray ~\package.json guard) → rebuild cost →
  projects + summary (stale/unpinned headlines).

- [x] **WIN-023: `GitInspection` — repo state from `.git`**
  `GitInspection.cs`: `GitState` (not-a-repo / no-remote / in-sync /
  differs(branches) / unknown) read from `.git` directly — config remote
  names, packed-refs + loose refs (recursive, branch names with slashes),
  refs/heads vs refs/remotes/<remote> comparison; `.git` as a file →
  worktree/submodule unknown. No subprocess, no network. Real-fixture
  test covers in-sync/differs/no-remote/not-a-repo.

- [x] **WIN-024: `.gitignore` oracle**
  `GitIgnoreRules` in `GitInspection.cs`: nested .gitignore files +
  .git/info/exclude, negation, anchoring, `**`, directory-only, `\`
  escapes; literal-name/name-suffix index so verdicts are O(1) lookups
  plus the few real globs; subtree walk truncates rules per folder
  depth and stops at nested repos. `IgnoredBytes` uses the scan tree for
  structure — disk reads are the ignore files only.

- [x] **WIN-025: `CleanupRecipes` + `cleanup-recipes.json`**
  `CleanupRecipes.cs` + embedded `cleanup-recipes.json` (separator-
  normalized matching). Windows command lines: `npm cache clean
  --force`, `pnpm store prune`, `yarn cache clean`, `dotnet nuget
  locals all --clear`, `go clean -modcache`, `pip cache purge`,
  `uv cache clean`, `vcpkg remove --outdated`; `trashIsUnsafe` on
  Docker Desktop's `Local\Docker` tree (the vhdx case). The developer
  page shows the command (click → copy + why-tooltip) instead of Stage
  when a recipe owns the path.

- [x] **WIN-026: `FolderInsight`**
  `FolderInsight.cs` — per-folder summary: composition via FileTypes,
  file/folder counts via RollUpCounts, largest files, honest
  reviewableBytes (>1y old files only, or the whole folder when a
  QuickWins hit marks it known-regenerable; 0 for protected paths via
  the queue's exclusion list), the "Mostly video (…)" why-large line.
  Feeds the inspector/Overview work.

- [x] **WIN-027: `StorageStories`**
  `StorageStories.cs` — `StorageNarrator.Stories` (capacity health,
  quick wins, forgotten, top-category, developer, largest file) +
  `Recommendations` (score = log(bytes)·confidence·safety), and the
  Overview "The story" card rendering them with byte figures.

- [x] **WIN-028: `StorageHistory`**
  `StorageHistory.cs`: one JSON per scanned root under `%LOCALAPPDATA%\
  DiskMap\History\<fnv-1a>.json`, atomic rewrite, retention = last of
  each day for 30 days then last per ISO week for a year; `Compare`
  picks the nearest-to-7-day base (≥5d) else oldest ≥2d, ≥100 MB
  growers, parent/child dedup (child wins at ≥80% of parent's growth;
  deep keys compare only when both scans went deep), sharing-mode and
  denied-count honesty flags. ScanModel records after every scan;
  Overview shows the growers card when history allows.

- [x] **WIN-029: `SavedSearch`**
  `SavedSearch.cs`: JSON store at `%LOCALAPPDATA%\DiskMap\
  saved-searches.json`, max 20, `Totals` = one count-only FileQuery pass
  per saved search (computed inside Collect, off the UI thread),
  `DefaultName` from `Describe()`. Find page: "Save search" button by
  the query box; saved queries render as pills with live matched-bytes;
  click runs them, right-click removes. (macOS puts them in the sidebar;
  here they live on the Find page — same function.)

---

## 4. Pages & navigation — P1

Current sidebar: Map · Top Sizes · Folders · Age Map · Sunburst · Flame ·
Bubbles · Mind Map · Snapshots · Duplicates · Quick Wins · Apps · Cleanup.
macOS sections: **Main** Overview · **Find** Find/Search/Biggest Files/
Biggest Folders/Forgotten Files/Duplicates · **Clean** Safe to Review/
Caches/Old Downloads/Large Media · **Explore** File Browser/Visualize/
Developer Storage/Regenerable Data/Applications/Snapshots — plus a
cleanup sheet, command palette, settings window, and menu-bar extra.
The Windows end state should be the same grouped sidebar.

- [x] **WIN-030: Sidebar grouped into sections + Overview page**
  Grouped sidebar (MAIN/FIND/CLEAN/EXPLORE/SAVED) + the Overview page —
  volume card with capacity bar + reconciliation line, exclusive
  category breakdown, largest opportunities, top files, access-denied
  banner, hard-link line, ReFS note, compressed/cloud bytes, the
  "what grew" card (WIN-028) and the story line (WIN-027) all land.

- [x] **WIN-031: Incremental rescan (USN journal)**
  `UsnJournal.cs` (FSCTL_QUERY/READ_USN_JOURNAL, record parsing, wrap
  detection), `ScanCache.cs` (baseline snapshot + journal marker per
  root under `%LOCALAPPDATA%\DiskMap\ScanCache`, atomic marker-then-tree
  writes), `IncrementalScan.cs` (replay → re-read touched FILE records
  → spec rebuild over the baseline tree; rename/move/hard-link
  reconciliation by name-claim; 64-folder spot check reusing the walk
  backend's exclusion rules). `ScanEngine` bookmarks the journal BEFORE
  any successful scan — both backends, since walk results carry file
  ids too — and tries replay first (`Backend = "usn"`). Fallbacks named
  in `FallbackReason`: no baseline, journal recreated/wrapped, change
  flood (>100k FRNs), spot-check disagreement, non-NTFS, needs admin.
  Tests: cache round-trip + unelevated fall-through; the elevated create
  +delete replay path is in `IncrementalScanTests` (admin-gated like the
  MFT tests).

- [x] **WIN-032: Find page + filter chips**
  `FindView.swift` (TASK-060): done — Find has its own sidebar row in
  the macOS order (and Ctrl+2 slot), a query box running the FileQuery
  language, the six suggestion chips (Large/Old/Duplicated/Cached/
  Media/Downloads), starter-query rows for its empty state, one Sort
  menu, the plain-language meaning line, per-token problems and
  `is:duplicate` explanation, match count + matched bytes, checkbox
  staging via the shared bottom bar, and saved searches (WIN-029).
  The shared row context menu (Reveal in Explorer / Copy Path / Show
  in Visualize / Add to Cleanup) covers the per-row actions.

- [x] **WIN-033: Search page**
  `SearchView.swift` — merged into Find: bare-word queries hit
  `FileSearch` (interned names, size-ranked), kind pills in the
  toolbar, row clicks select into the inspector, rows get the shared
  context menu (Reveal / Copy Path / Show in Visualize / Add to Cleanup),
  and double-click reveals files in Explorer while dirs drill — the
  remaining "show in map" jump and open-on-double-click both landed.

- [x] **WIN-034: Biggest Files + Biggest Folders**
  Separate file-only and folder-only ranked pages exist with staged
  checkboxes and the shared toolbar. OneDrive icons on not-downloaded
  rows — tracked under WIN-046.

- [x] **WIN-035: Forgotten Files page** — `AgeMap.Untouched` + stat cards
  + age distribution bar + staging.

- [x] **WIN-036: Safe to Review page** — landing card grid + regenerable
  categories with review links and staged rows.

- [x] **WIN-037: Caches page** — cache-category quick-win hits, safety
  badges, checkboxes + selection bar staging.

- [x] **WIN-038: Old Downloads page** — files inside any Downloads
  folder, ranked + staged.

- [x] **WIN-039: Large Media page** — video/audio/image >100 MB with
  type and age breakdowns + staged.

- [x] **WIN-040: File Browser page** — children of the zoomed folder with
  breadcrumb bar (with back/forward + Focus), folder header card
  (size, items, type bar), sortable list, staging.

- [x] **WIN-041: Developer Storage page** — hero stats (total /
  reclaimable+share / stale-projects bytes / unpinned deps), category
  strip, project cards (manifest + lockfile + rebuild-cost + status
  badges, git state line, git-ignored bytes, per-project "Stage
  reclaimable"), and the all-locations list where `trashIsUnsafe`
  recipes render as a Copyable command steer instead of a Stage button
  (VHDX-safe). Select/drill wired like every list.

- [x] **WIN-042: Regenerable Data page** — decided: folded into the
  categorized Quick Wins page + the Safe to Review landing, which carry
  the per-category groupings macOS shows. Sidebar slot covered by
  "Safe to Review".

- [x] **WIN-043: Applications page parity check** — registry listing +
  name-matched leftovers was already live. Added: per-app **footprint**
  column (install dir + leftover bytes summed), a "Copy uninstall
  command" row-menu item reading `QuietUninstallString`/`UninstallString`
  (revealed, never executed — the queue still owns removal), and a
  "Store apps" section enumerating MSIX packages from the per-user
  `AppModel\Repository\Packages` hive (the no-WinRT path — a versioned
  SDK TFM would be needed for `PackageManager`), sized via
  `PackageRootFolder`.

- [x] **WIN-044: Snapshot compare v2**
  `SnapshotComparison.cs` (TASK-071 port): lazy per-level alignment by
  child-name dictionary — no full-path pass; `ChildrenOf` rows sum to
  their folder; `EntryAt` breadcrumb walk; `Hotspots` descends only
  where ≤3 same-direction children explain ≥80%, stopping at files,
  added/removed whole units, or spread-change folders; different-roots
  warning. The Snapshots compare UI now shows net + grew/freed split,
  the hotspot story, breadcrumbs, and drillable rows (before → after →
  delta) — the flat path-diff is gone.

- [x] **WIN-045: Interactive Age Map** — Forgotten Files' age-bar
  legend dots toggle a band filter (bold + • marker when active,
  "Clear age filter" pill to revert). The list then shows only that
  bucket; stats stay whole-set.

- [x] **WIN-046: Cloud icons on not-downloaded rows** — shared table
  rows (Biggest Files/Folders, Forgotten, Media, Downloads, File
  Browser, Search) swap the type tile for a "☁" tile in light blue and
  add "cloud-only — opening downloads it" to the subtitle, so Reveal's
  recall cost is visible before it happens.

---

## 5. Visualize shell & inspector — P1/P2

macOS folded all 8 modes into one **Visualize** destination with shared
chrome (`ExploreShellView`, `LayoutChartView`, `ExploreColoring`):
view-mode picker, depth slider, coloring modes, and an inspector column.
Windows kept each mode as its own sidebar page — fine as an incremental
state, but the inspector and coloring layers are missing entirely.

- [x] **WIN-047: Inspector panel** — `Controls/InspectorPanel.cs` is the
  persistent right column on every page: DETAILS (location+copy, size
  with % of used + bar, items, modified, created from WIN-001's
  createdDay, and now "On disk + compressed by" via
  `Model.DualTotals`), "What's inside" type composition + Contents tab
  (Largest Inside), why-large explanation, removability verdict +
  risk badge, actions (Reveal / Open containing / Copy Path /
  Visualize / Move to Recycle Bin via Stage). Selection syncs from
  every chart tile and table row through `Model.InspectedNode`.

- [x] **WIN-048: Coloring modes (folder / type / age) + depth slider**
  `ChartLayout.SlicesOf` takes `otherFraction` (the old 0.005 const
  stays the default); the Visualize toolbar has Type/Folder/Age pills
  (model `ColoringMode`) and a Depth slider (0.01%→2% collapse
  threshold → `ChartDepth`). `TreemapControl.FillFor` dispatches: type
  = dominant kind pastel, age = dominant AgeBucket on the Forgotten
  ramp, folder = stable name-hash hue; sub-threshold children collapse
  into a non-drillable "Other (N)" tile in every chart.

- [x] **WIN-049: Mind map v2 labels** (TASK-070) — the collapse
  threshold rides the shared depth slider (ChartLayout otherFraction);
  folder labels read "name — total · N items" via `Model.Counts`; the
  collapsed slice is a "+N more · X GB — open" card (`HiddenCount` on
  ChartSlice) that drills into its parent rather than being a dead
  tile; elbow connectors come from the measured rects.

- [x] **WIN-050: Chart chrome polish** — a live legend row under the
  toolbar explains the active coloring (age buckets with their swatch
  colors, type/folder semantics, gray = Other); labels already size to
  their slice (treemap suppresses labels on tiny cells, sunburst/
  mind-map ellipsis); every chart keeps the "Nothing to visualize —
  scan first" empty state; the 60-item accessible list landed with
  WIN-061.

---

## 6. Cross-cutting UX — P2

- [x] **WIN-051: Keyboard system** — `Keyboard.swift` (TASK-062) ported
  as one `PreviewKeyDown` on the window: ↑/↓/j/k move the row selection
  through the active list page (`FileListPage.NavigateSelection`, row
  highlight repaints via the `_rowBorders` map), Enter activates (drill
  for dirs, Reveal for files), Delete or Ctrl+Backspace stages via the
  page's own reason, Ctrl+↓/↑ drill into/out of the selection, Ctrl+1–9
  jumps destinations in sidebar order (Overview then Find), Ctrl+K/F
  opens the palette, Ctrl+Shift+Delete opens Cleanup, Ctrl+R rescans,
  Ctrl+Shift+R drops `ScanCache` then rescans (true full rescan).
  TextBox focus swallows its own keys first.

- [x] **WIN-052: Multi-selection** — `ScanModel.MultiSelection`
  (shared set): Ctrl+click toggles a treemap cell (accent outline),
  plain click resets to single, Esc clears; the Visualize strip shows
  count + bytes with folder-coverage dedup (`MultiSelectionBytes`
  skips ids whose ancestor is also selected), Add to Cleanup, Copy
  Paths (quoted when needed), Clear. On list pages Ctrl+A checks the
  filtered set and Esc unchecks; the existing checkbox bottom bar
  stays the list-side multi-select UI.

- [x] **WIN-053: Command palette** — Ctrl+K (or clicking/focusing the
  top bar) opens a `Popup` under the search host: its own query input,
  the plain-language meaning line via `Query.Describe()` + per-token
  "not understood" problems, live top-8 hits with sizes (structured
  queries through FileQuery, bare words through FileSearch — same
  engines as Find), "Show all results in Find", and the saved-searches
  list when the box is empty. Enter runs the query in Find; Esc closes.

- [x] **WIN-054: Copy Paths + Export scan**
  `TreeExporter.cs` (TASK-058 port): nested JSON, NDJSON, RFC 4180 CSV,
  ncdu `-o` (`asize`/`dsize`, flag hex) — pure logic over FileTree +
  totals. "Export Scan…" sits on the Snapshots header with a format
  dropdown. Copy Paths = the bottom-bar "Copy paths" (newline-joined,
  `QuotePathIfNeeded` double-quotes only when a space/cmd metachar
  demands — Windows quoting, not `sh`). 5 exporter tests.

- [x] **WIN-055: Drag-to-scan + command-line arg** — window-level
  AllowDrop: DragOver shows Link only when a directory is under the
  cursor (files ⊘), Drop starts the scan. argv[0] directory → scanned
  on load (takes precedence over the dev autoscan env hook). Explorer
  context-menu verb deferred to packaging (WIN-073 decides the MSIX
  `fileTypeAssociation`; not silently writing shell registry keys).

- [x] **WIN-056: Menu bar / window chrome** — a "☰ DiskMap" top-bar
  button opens the window menu: Scan Folder…, Rescan (Ctrl+R), Full
  Rescan (Ctrl+Shift+R — drops the journal baseline first), Export
  Scan… (the same 4-format Save dialog), Put Back Last Cleanup
  (enabled only when a record exists → Cleanup page), a Go submenu
  listing every destination, Exit. The staging toast (WIN-063) covers
  the per-stage affordance. View-menu appearance/text-size entries
  arrive with WIN-058/059.

- [x] **WIN-057: Tray icon (menu-bar-extra counterpart)** —
  `TrayIcon.cs` (NotifyIcon, `UseWindowsForms` with the WinForms/
  Drawing implicit usings removed so WPF names stay clean): passive
  context menu — free space with ⚠-low under 10%, last-scan
  path+size line, Δ-since-last-scan ("Free space −X this week ·
  <folder> +Y" from `HistoryComparison` — free delta + biggest
  grower), Rescan (enabled only when a scan exists and none is
  running), Open DiskMap (double-click too), Quit. Repaints on
  `StateChanged`.
  `GetDiskFreeSpaceEx` poll on a timer, no background scanning.
  WPF `NotifyIcon` (needs a Forms reference or a small interop wrapper).

- [x] **WIN-058: Appearance + dark mode** — `AppSettings` (JSON at
  %LOCALAPPDATA%\DiskMap\settings.json) carries `appearance` =
  system|light|dark; "system" reads `AppsUseLightTheme`. `Theme.Apply`
  now takes the resolved flag and fills the existing dark palette
  values; the Fluent `ThemeMode` follows; the View → Appearance menu
  (File menu) switches live and rebuilds the code-built shell, nav,
  pages and inspector. Windows High Contrast swaps the Calm `line`,
  `ink2` and `ink3` values to the DESIGN.md HC values at startup and
  when the OS setting changes. Chart tiles keep the fixed data palette.

- [x] **WIN-059: Text size scaling** — `AppSettings.textScale` uses
  DESIGN.md's 0.9/1.0/1.15/1.3 choices (Smaller/Default/Larger/
  Largest), applies to page and inspector content, and grows the
  sidebar from its 212 px base so labels still fit. View → Text size
  and Settings share the values and persist across launches.

- [x] **WIN-060: Settings window** — `SettingsWindow.cs` (Ctrl+, — the
  ⌘, convention — and File → Settings…). Carries Appearance
  (Follow Windows/Light/Dark pills — same callback as View →
  Appearance), Text size (4 pills), "Keep storage history" (default
  on — feeds `HistoryComparison` and the tray Δ), and "Count block
  clones once on ReFS volumes" (default off — WIN-066's gate). Scan
  toggles persist via `AppSettings`; the next scan reads them.
  Appearance/text-scale apply live through `MainWindow`'s existing
  callbacks.

- [x] **WIN-061: Accessibility** — the treemap is `Focusable` and
  carries a `TreemapPeer` automation peer: the control announces
  "Storage treemap — <folder>, N cells" and exposes its top 60 cells as
  ListItem peers named "name, size, share, folder — double-click to
  enter" (the macOS accessible-list cap). Arrow keys move selection
  across cells in layout order; Enter drills. The other four charts
  (sunburst, flame, bubbles, mind map) got the same contract:
  `Focusable`, the shared `ChartNavigation` model (←/→ siblings,
  ↑ parent, ↓ first child, Enter drills, Esc clears multi),
  click-selects / Ctrl+click multi / double-click drills with the
  treemap's white + accent selection strokes, and a `ChartPeer`
  announcing "<chart> — <folder>" with the top-60 accessible items.
  List pages already expose rows as focusable checkboxes with names —
  Narrator reads them through the standard WPF peers.

- [x] **WIN-062: Quick Look counterpart — decided.** Windows' honest
  equivalent is the one chosen: Reveal in Explorer + the inspector's
  Overview/Contents/Insights detail tabs (WIN-047) carry the "what is
  this file" answer; `IPreviewHandler` hosting was considered and
  rejected — fragile out-of-proc shell previewers for a marginal gain.
  Space on a list page activates the row (drill/reveal), matching the
  Quick Look trigger spot.

- [x] **WIN-063: First-run hero + toasts** — Overview's empty state is
  now the hero: headline, three numbered cards teaching
  scan → explore → clean up, the scan button, and a drag-a-folder hint
  (WIN-055). Adding one or many items stays on the current page and
  shows the standard raised toast ("Added to Cleanup — Ctrl+Shift+
  Delete to review"); only the shell button, shortcut, or an existing
  "In Cleanup" action opens Cleanup. Commit and Put Back also toast.

- [x] **WIN-064: Rescan button + short-window scrolling** — verified
  by construction: every page derives from `ListPage` whose Content is
  a `ScrollViewer` — a 600 px window reaches every control. The rescan
  affordance is on every list-page bottom bar plus the File menu
  (Ctrl+R) and full rescan (Ctrl+Shift+R).

- [x] **WIN-065: Saved searches sidebar** — WIN-029 + UI: "Saved"
  section under Find (outside numbered shortcuts), live size per
  search, Rename/Move/Remove, starter suggestions in Find's empty
  state, palette listing.

---

## 7. Correctness & accounting extras — P1/P2

- [x] **WIN-066: Clone-aware totals (ReFS), opt-in** — the extent
  pass exists and is opt-in (`AppSettings.cloneAccounting` — Settings
  → "Count block clones once on ReFS volumes", off by default; CLI
  `--clones`). `BlockClones.Profile` runs after the walk when the
  root's volume reports ReFS: dedupes inodes, one
  `FSCTL_GET_RETRIEVAL_POINTERS` map per inode (parallel, progress
  reported), sweeps overlapping physical ranges, union-finds them
  into clone families, and installs a `SharingTable` on the tree.
  `FileTree` grew the macOS machinery verbatim: `SharingTable`
  (node/cloneId/privateBytes/refcount rows), `CloneGrouping` —
  lowest-inode member of each family elected to carry the shared
  blocks, others charged only private bytes — `GetSharingCorrection`,
  `SharingInfoOf`, and the `NodeFlags.FileClone` flag. The snapshot
  codec writes real v4 rows (mode 2) and decodes rows from either
  platform — a macOS APFS file's clone facts now apply here and vice
  versa. Overview reports "N cloned copies in M groups share X —
  counted once" when the pass found clones, "no cloned copies" when
  it ran clean, and the enable hint otherwise. History entries record
  `blockclone-dedup` so mode-mismatched scans never compare.
  Honest limits, documented in `BlockClones`: extents shared with
  copies outside the scanned root are invisible to
  FSCTL_GET_RETRIEVAL_POINTERS (unlike APFS refcounts), so no
  refcount-1 "partial" rows are produced — such files count once,
  which is the same answer hard links give for names outside the
  root. Tests cover the sweep (synthetic extent maps — chained
  sharing, private-byte splits, sparse-run rejection), the rollup
  charges, codec round-trips, and row validation; the ioctl path
  needs a real ReFS fixture (none on CI — same rule as the MFT
  tests).

- [x] **WIN-067: Snapshot codec convergence** — done via option (a),
  full tracking: the Windows codec now writes DMAP **v4** (fileIDs +
  sharing table + sharing mode) and reads every macOS version 1–4
  (v2 createdDay, v3 fileID, v4 sharing). `SnapshotCodecVersionTests`
  pins a hand-built v1 blob decoding and a full v4 round-trip, so a
  macOS-saved file decodes here and vice versa — `windows/README.md`'s
  "interchangeable" claim is true again.

- [x] **WIN-068: Fresh-clone correctness check** — the Windows analog
  is the sparse/extent gap: a `FSCTL_SET_SPARSE` + seek-tail file is
  64 MB logical with ≈nothing allocated. `SparseFileAllocatedDiffersFromLogical`
  pins that the walk reports `AllocatedSize ≪ LogicalSize` (after
  `FlushFileBuffers` writeback) — the invariant `AreLikelyClones` and
  "compressed by" both read from. Real temp fixture, no mocks.

- [x] **WIN-069: Excluded-paths review pass** — audit done; TWO
  additions (called out per the rule):
  `%LOCALAPPDATA%\Microsoft\WindowsApps` (execution-alias reparse
  points — NOT covered by the `Microsoft\Windows` prefix), and the
  drive-root memory files `pagefile.sys`/`hiberfil.sys`/`swapfile.sys`
  (exact-name entries). WinSxS confirmed refused via the `C:\Windows`
  prefix; user-profile junctions never reach staging because the
  scanner skips non-cloud reparse points. `ExcludedListCoversAuditedPaths`
  pins the whole set.

---

## 8. CLI & export — P2

- [x] **WIN-070: `diskmap` CLI** — `app/DiskMap.Cli`, a console
  project on DiskMap.Core only: `scan --json [--clones]`,
  `find <path> <query>` (FileQuery structured + bare words), `dup`,
  `dev [--reclaimable] [--older-than 6m] [--json]` (the
  `DeveloperCatalog` model — projects, items, rebuild commands, stale
  filters — the macOS `diskmap dev` counterpart), `export
  [--json|--ndjson|--csv|--ncdu]`, `check --fail-over 50GB`. Exit
  codes 0/1/2/3; SI sizes + GiB; the engine's scan summary moved to
  stderr and progress only renders on a terminal, so `--json` stdout
  stays clean.

- [x] **WIN-071: Bench harness** — `diskmap bench <path>
  [--repeat N] [--json]`: per-run backend/items/seconds/peak-RSS rows
  (the timing points already in `ScanEngine`), JSON array for a
  `docs/perf-results/` trail. This is the gate for WIN-066's extent
  pass and MFT-vs-walk regression tracking.

---

## 9. Packaging & distribution — P2

- [x] **WIN-072: Elevation UX decision — keep `requireAdministrator`.**
  The maintainer already chose this in `app.manifest` (2026-10-03):
  the MFT fast path and protected-directory reads need admin, and the
  honest UX is WizTree's — one UAC prompt at launch, then everything
  works (MFT scan, USN replay, seeded staging, no "needs admin"
  caveats). An asInvoker + elevate-on-demand variant would split the
  app into two reliability tiers for a cosmetic gain; not worth the
  dual-path testing burden.

- [x] **WIN-073: Packaging — portable single-file exe for now.**
  `dotnet publish app/DiskMap.App -c Release -r win-x64
  --self-contained -p:PublishSingleFile=true` produces one
  `DiskMap.exe` (icon via ApplicationIcon already) — no installer
  needed for a disk tool, no MSIX identity to maintain, and the
  Explorer "Scan with DiskMap" verb (WIN-055) stays a deliberate
  registry choice the user opts into, not an installer side effect.
  MSIX remains the right move if a Store listing ever happens; the
  manifest decision is reversible — code has no packaging coupling.

- [x] **WIN-074: Update mechanism decision — no updater.**
  Offline-purist default, matching macOS's Sparkle-off-by-default
  stance minus even the opt-in: releases ship as artifacts (WIN-073)
  and users update by downloading. If an opt-in checker ever lands it
  must be the single networked file — `NetworkPolicyTests` now greps
  `src/` + `app/` for HttpClient/WebRequest/etc. and fails the build,
  the same guard macOS has.

---

## 10. Windows-only opportunities (beyond parity)

Not required for parity, but structural advantages the platform gives —
same spirit as the macOS "do better" list. Track here so they aren't lost.

- [x] **WIN-075: WSL/VHD awareness** — `developer-rules.json` marks
  `LocalState`/`DockerDesktopWSL`/`wsl` dirs as `keep` + containers:
  the Developer page shows them with "an ext4.vhdx in here IS the
  distro's disk — recycling destroys the distro" (the trashIsUnsafe
  equivalent — keep is never offered for staging).
- [x] **WIN-076: NTFS compression surface** — the scan records
  `AllocationSize` (compressed) vs `LogicalSize` inline; Overview's
  health card now reports "N GB of scanned data is already compressed
  or sparse" when >256 MB. Show, never run — `compact /c` stays an
  Explorer/CLI action, matching the recipes philosophy.
- [x] **WIN-077: OneDrive Files On-Demand depth** — cloud-only bytes
  (FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS) sum into an Overview line:
  "N GB lives only in the cloud — evicting those files frees the space
  without deleting them." Eviction stays an Explorer action (Free up
  space); rows already carry the ☁ badge and Reveal recalls nothing
  extra — the honest show-don't-run surface.
- [x] **WIN-078: Previous-versions reconciliation** — on a drive-root
  scan, `System Volume Information` shows up as a DENIED directory;
  the reconciliation line then names it concretely: "restore points
  and VSS shadow copies live in System Volume Information (which
  Windows won't let us read)". No vssadmin subprocess needed — the
  honest label is the ask.

---

## 11. Tests & tooling

- [x] **WIN-079: Port feature tests as features land** — the suite is
  at 116 tests covering the ported surface: identity/creation-day,
  hard links (real `CreateHardLinkW`), denied dirs, cancellation,
  codec v1–v4, incremental rescan, seeded staging, cleanup reclaim/
  ordering/receipt, put back, FileQuery, dev catalog, saved searches,
  storage history, snapshot compare, insights/stories, exporter,
  excluded-paths audit, sparse-file accounting, block-clone family
  math + rollup charges + sharing codec round-trips, network policy.
  Style: real temp dirs, never mocks — the macOS fixture contract.
- [x] **WIN-080: Visual/snapshot harness** — `DISKMAP_AUTOSCAN` +
  `DISKMAP_PAGE` launch hooks render the real window into any state;
  `DISKMAP_SHOT=<png>` (`DISKMAP_SHOT_SETTLE`, `DISKMAP_SHOT_QUIT=0` to
  keep the window) writes a `RenderTargetBitmap` PNG and exits — the
  `--snapshot-dir` counterpart. Run it via `dotnet DiskMap.App.dll`
  (no manifest elevation, no z-order dependency). The codebase's
  `UNVERIFIED`-on-render policy keeps golden-PNG diffing out of scope
  (no stable font/DPI baseline in CI — an eyeball pass is the honest
  affordance, and it exists). `windows/scripts/capture-window.ps1`
  remains for non-elevated window grabs.
- [x] **WIN-081: README mapping current** — table updated: the walk is
  `NtQueryDirectoryFile` (not FindFirstFileExW), file-id entry added,
  FSEvents→USN journal, trashItem→SHFileOperation + `$I` Put Back,
  menu-bar extra→NotifyIcon, ⌘K→Ctrl+K palette, apps→registry+MSIX,
  Sparkle→no-updater + the network guard test. Stale claims fixed:
  hard links now dedupe on BOTH backends; snapshots interchangeable
  again (v4 write / v1–4 read); CLI added to layout.

---

## 12. Calm design parity audit

- [x] **WIN-082: Current DESIGN.md shell, controls and cleanup grammar**
  Find is a first-class sidebar destination; the shell uses the 212 px
  single-surface sidebar, 44 px top bar, DiskMap mark, hairline volume
  footer, raised toast and 880 × 600 minimum window; below 1200 px the
  inspector becomes a top-bar-controlled overlay drawer, and below
  1000 px the sidebar does the same. Shared titles,
  buttons, chips, search fields, checkboxes, figure strips and safety
  labels now use shared Calm spacing, row heights and vertical alignment.
  Page navigation resets stale scroll positions. The top bar exposes a
  visible light/dark toggle, while View and Settings retain System mode.
  A licensed, 8 KB subset of Google Material Symbols Rounded is bundled
  as a WPF resource, so file/folder/navigation icons are consistent and
  remain fully offline. The fixed data and age palettes replace legacy
  blue/green/red view colors; High Contrast uses the documented line/ink
  values. Staging is
  consistently called "Add to Cleanup", never navigates automatically,
  disables protected/keeper actions, and batches its toast. The
  inspector no longer presents staging as an immediate Recycle Bin
  action or repeats the safety verdict. Snapshot removal now enters
  Cleanup instead of calling `File.Delete`. The Windows excluded-paths
  list was not changed.

- [x] **WIN-083: freedisk.space 0.2.0 release parity** — the public name,
  Dusty app icon and About surface now match main while internal assembly,
  cache and preference names remain compatible. Show Dusty is optional;
  the mascot appears in empty/first-run/scanning states and after a cleanup,
  never on the Recycle Bin confirmation step. Search fields use the new
  32 px raised/hover/focus treatment and Esc-to-clear. Cleanup removal has
  a six-second exact Undo, and a successful commit becomes an in-page Put
  Back/Done result. File Browser no longer repeats the current folder in its
  breadcrumb; Age Map hides its irrelevant color control; Flame requests a
  four-level icicle hierarchy; all layout charts honor folder/type/age color
  modes. Developer legends wrap and Snapshots stack at narrow widths.

---

## Suggested order

P0 correctness first — they fix numbers users already see, exactly like
the macOS trust pass (Milestone 7):

1. WIN-001 identity → WIN-002 walk hard links → WIN-009/WIN-010 reclaim
   math & receipt → WIN-003 denied dirs → WIN-004 cancellation audit.
2. Then the leverage ports: WIN-016 FileQuery, WIN-015 file types,
   WIN-014/WIN-005 volume+reconciliation → WIN-030 Overview, WIN-032
   Find, and the catalog pages WIN-018/019/020/021 → WIN-035..039.
3. WIN-031 incremental rescan is its own milestone — do it once
   WIN-001 identity and codec versioning (WIN-067) exist.
4. Visualize shell (WIN-047..050) and the UX layer (WIN-051..065) after
   the pages exist; CLI (WIN-070) once catalogs it calls exist.
5. Packaging/elevation/updater (WIN-072..074) last, when the app is
   worth shipping.
