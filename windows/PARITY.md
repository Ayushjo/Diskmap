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

- [ ] **WIN-001: File identity in `FileTree` — file index + link count**
  macOS: TASK-036 (`fileID: [UInt64]` array, `hardLink` flag, +8 B/node).
  Windows: add `FileId` (`long[]`) to `FileTree`, snapshot codec, and
  `AddNode` defaults. `GetFileInformationByHandle` gives
  `nFileIndexHigh/Low` + `nNumberOfLinks` in one call; the MFT path already
  has both for free (record number + `$FILE_NAME` link counting).
  Prerequisite for WIN-002, WIN-005, WIN-006, and honest duplicate
  handling. Also add `createdDay` (`int[]`, days since epoch) here — the
  inspector's "Created" line (TASK-031) needs it, MFT `$STANDARD_INFORMATION`
  and `WIN32_FIND_DATA.ftCreationTime` both provide it.

- [ ] **WIN-002: Hard-link-aware rollups in the walk backend**
  macOS: TASK-037 (suppress duplicates inside `ownSize`; election by lowest
  path, not node id, for snapshot-diff stability; group-of-one outside the
  root keeps full size).
  Windows gap, documented in `windows/README.md`: the MFT path charges
  once, but `Win32Scanner` can't see link counts, so WinSxS-heavy totals
  differ by backend. With WIN-001's file id + link count read during the
  walk (`GetFileInformationByHandle`), unify both backends: same
  charge-once-by-lowest-path rule, exposed as a named correction figure
  like `hardLinkCorrection` so the UI can explain why totals differ from
  `dir`-style counting. Tests: real `CreateHardLinkW` fixture, assert the
  parent counts it once — mirror `HardLinkRollupTests`.

- [ ] **WIN-003: Report unreadable/denied directories**
  macOS: TASK-039 (`deniedDirectoryIDs` via `errno`, EACCES/EPERM surfaced
  vs ENOENT mid-scan deletion vs ELOOP; banner + example paths in Overview).
  Windows: `FindFirstFileExW`/`FindNextFileW` failing with
  `ERROR_ACCESS_DENIED` (and MFT-equivalent skips) are currently silent —
  a non-admin scan reports confidently wrong totals. Capture the error in
  the walk, carry `DeniedDirectoryIDs` + counts through
  `WalkResult`→`ScanEngine.Result`→`ScanModel`, show an inline banner
  ("N folders couldn't be read — run as administrator for a complete
  scan"). Test: `icacls`-denied fixture directory.

- [ ] **WIN-004: Scan cancellation + termination audit**
  macOS: TASK-065 (dropped-subtree race — `publishing` counter in the
  termination condition), TASK-066 (thread-pool starvation deadlock),
  `scanGeneration` cancellation guard.
  Windows: `ScanAsync` takes no `CancellationToken`; audit
  `Win32Scanner`'s work-queue termination for the same dropped-subtree
  shape (a dequeued-but-unpublished batch must count as in-flight). Add a
  "many concurrent scans all finish" + "cancel mid-scan" test mirroring
  `ScanTerminationTests`.

- [ ] **WIN-005: Volume stats + scan reconciliation**
  macOS: TASK-040 (`statfs` used vs scanned bytes, `unaccountedBytes`,
  "this scan accounts for X of the Y in use", honest copy listing causes:
  other volumes, VSS/restore points, unreadable folders; never inflate a
  category to close the gap).
  Windows: `GetDiskFreeSpaceExW` already exists in `Win32.cs`. Feed it
  into an `AnalysisSnapshot`-style core type (WIN-014) and the Overview
  page (WIN-017). Windows-specific unaccounted causes worth naming:
  `System Volume Information` (VSS/previous versions — excluded path,
  never scanned), other volumes mounted under the root, hard links
  already deduped, the MFT-resident metadata itself.

- [ ] **WIN-006: Streaming scan progress**
  macOS: TASK-044 — publisher keeps running per-top-level totals (each
  job carries its top-level ancestor, O(1) attribution), emits a
  `ScanProgress` every 250 ms: items, bytes, items/s, current folder,
  largest top-level folders.
  Windows: `ScanProgress` is an items count only. Add the same running
  top-level attribution (MFT records carry parent chains already — map
  each record to the scan root's immediate children; walk jobs can carry
  the ancestor id), a `ScanProgress` report type, and a live scanning
  screen (bar per top-level folder filling in). Cheap, biggest perceived-
  speed win available.

- [ ] **WIN-007: Phase indicator + post-walk narration**
  macOS: TASK-046 — headline follows the real phase (walking →
  "Summarizing…"), not item-count thresholds.
  Windows: status line says "Scanning… N items" then nothing during
  rollup/compact. Report walk vs rollup vs layout phases through
  `ScanModel`; show items/s during the walk.

- [ ] **WIN-008: `rollUpDescendantCounts`**
  macOS: post-scan iterative pass giving every directory its item count —
  drives "N items" labels, the mind map's real totals, and several
  inspector lines. Windows `FileTree` has nothing equivalent; every page
  would need it as pages land.

---

## 2. Cleanup correctness — P0

- [ ] **WIN-009: True reclaim math inside `CleanupQueue`**
  macOS: TASK-038 — `stage()` itself measures sharing (dev/ino/nlink per
  staged path; hard-link inode charged once only when every name staged;
  clone families via sharing profile; items inside a staged folder counted
  once via the folder). No call site can get it wrong.
  Windows gap: `Stage()` trusts the caller's `size` and an optional
  `sharesStorageGroup` that only DuplicatesPage passes. Every other
  surface (Quick Wins, Apps, Age Map, right-click staging) overcounts
  hard links and clones. Port the shape: `stage()` does one
  `GetFileInformationByHandle` → (volume serial, file index, link count);
  `TotalSize()` charges a multiply-linked file index once when staged
  count reaches `nNumberOfLinks`; ReFS clones via memoized extent-map
  compare (CloneDetector exists — memoize `ExtentMapOf` by path, it's
  currently re-read per pair, and `PartitionClones` is O(k²)); containment
  dedup when a staged folder covers staged children. Extend
  `ScanAndFeatureTests` with a real hard-link fixture (one already
  exists — `CreateHardLinkW` in the test file).

- [ ] **WIN-010: Honest commit receipt + folder-first commit ordering**
  macOS: TASK-038 — receipt recomputed over successes; "freed when you
  empty the Recycle Bin"; "at least" wording when shared blocks can't be
  attributed; children of a committed folder report "moved with its
  folder" instead of retrying as failures; bounded report view.
  Windows: `Commit()` recycles items serially in stage order — a child
  staged before its parent folder fails after the parent moved. Sort
  parents-first, mark covered children "moved with folder", and write a
  receipt the UI shows (count + honest freed figure), not just
  "N recycled, M failed".

- [ ] **WIN-011: Non-blocking staged-folder measurement**
  macOS: staging a folder measures its real size in the background
  (single-threaded walk; `isCalculating`; commit disabled until known).
  Windows: `Stage(path, size)` takes the caller's number — a folder staged
  from a context menu or list carries a guess. Measure staged folders
  ourselves (respect reparse-point and cloud-placeholder rules identical
  to the scan) so the confirm dialog shows a real figure.

- [ ] **WIN-012: Put Back last cleanup**
  macOS: TASK-080 — `last-cleanup.json` (original path, trash path,
  bytes); restore only when still in Trash and the old path is free;
  missing parents recreated; skips explained; receipt lists skips.
  Windows has no put-back API. Options in order of preference: (a)
  record each committed item's original path, locate its entry in
  `shell:::{645FF040-...}` (Recycle Bin folder view) and invoke the
  `Restore` verb via `Shell.Application` COM — restores ACLs/metadata
  properly; (b) parse `$I` metadata files under `$Recycle.Bin` and move
  the `$R` payloads back — faster but bypasses the shell bookkeeping.
  Prototype (a) first; fall back to (b) with a test against a temp
  "recycle bin" seam, never the real one (mirror `PutBackTests`).

- [ ] **WIN-013: Seeded (instant) staging measurement**
  macOS: TASK-082 — after a full-accuracy scan, staging a folder reads
  its subtree straight from the tree (0.06 s vs 4.6 s walked) after
  confirming nothing under it changed; falls back to the walk with a
  reason. Exactness-gated: only when the scan had full sharing facts.
  Windows: needs WIN-001 identity + the scan-context hook
  (`CleanupQueue.setScanContext` equivalent) + the change check (USN
  journal, see WIN-031). Later — design it when WIN-009 and WIN-031 exist.

---

## 3. Core catalogs & queries — P1

All run on the existing `FileTree` + totals from one walk; no second disk
pass. macOS reference files are named per item; all belong under
`src/DiskMap.Core/` with data JSON beside `quick-wins-patterns.json`.

- [ ] **WIN-014: `AnalysisSnapshot` + volume stats core type**
  `AnalysisSnapshot.swift`, `VolumeStats.swift` — category totals, volume
  figures, reconciliation (WIN-005), the data behind Overview. Windows:
  new `AnalysisSnapshot.cs` + `VolumeStats.cs`.

- [ ] **WIN-015: `FileTypeCatalog` + `file-type-categories.json`**
  Port the JSON verbatim (it's data). Feeds: Overview folder-mode
  categories, treemap color-by-type, `kind:`/`type:` query tokens, the
  File Types panel, per-type colors in charts.

- [ ] **WIN-016: `FileQuery` — the Find query language**
  `FileQuery.swift`: `ext: name: kind: size>/< age>/< path: in: is: type:`,
  bare words, `-word`, quoted values; bad tokens reported per token and
  excluded (a half-typed `size>` never empties results); matched-bytes
  rule (a folder inside a matched folder counts once). Performance
  approach to port too: name tests once per interned name, literal
  prefilter before wildcard, top-N by heap — no per-node path building.
  This is the engine for the Find page, ⌘K-equivalent, saved searches,
  and the CLI. Biggest single-leverage port.

- [ ] **WIN-017: `FileSearchIndex` — find-as-you-type name search**
  `FileSearch.swift`: substring match once per interned name, node ids
  grouped by name id (counting sort), ranked by size via bounded insert.
  Powers the Search page.

- [ ] **WIN-018: `OldDownloadsCatalog`**
  `OldDownloadsCatalog.swift` — aging/size analysis of the Downloads
  folder. Windows: `%USERPROFILE%\Downloads` detected by path, same
  rules.

- [ ] **WIN-019: `MediaCatalog` (Large Media)**
  `MediaCatalog.swift` — photo/video/audio over a size threshold,
  sorted. Extension sets come from `file-type-categories.json`
  (WIN-015), not a hardcoded list.

- [ ] **WIN-020: `ForgottenFiles`**
  `ForgottenFiles.swift` — large files untouched for a long time,
  distinct from Age Map's bucket view.

- [ ] **WIN-021: `ReviewableTargets` + `SafetyClassification`**
  `ReviewableTargets.swift`, `SafetyClassification.swift` — the "Safe to
  Review" catalog: conservative suggestions with a why-it's-safe note.
  Bias to fewer false positives (rule 5).

- [ ] **WIN-022: `DeveloperCatalog` v2 + `developer-rules.json`**
  `DeveloperCatalog.swift`, `DeveloperProjects.swift`,
  `developer-rules.json` (Milestone 11, TASK-051/052/056):
  - Project roots by manifest (`package.json`, `Cargo.toml`, `go.mod`,
    `pyproject.toml`, `*.csproj`/`*.sln`/`*.slnx`, `pom.xml`, …) — add
    the .NET/Java-Windows manifest names to the rules JSON, don't
    hardcode.
  - Rebuild cost classes: free / cheap / networked / networked-unpinned
    (lockfile detection incl. workspace-root lockfiles).
  - Project aging: max mtime excluding reclaimable subtrees → the
    "N projects untouched for 6+ months hold X" headline.
  - Windows extras worth rules: `.nuget` packages cache, `.vs`,
    `bin/`/`obj/` (careful — these live inside projects, match as
    reclaimable only under a manifest root), `%LOCALAPPDATA%\pip\cache`,
    Gradle/Maven caches, `node_modules` (already in quick-wins),
    WSL/Docker vhdx files (see WIN-048).

- [ ] **WIN-023: `GitInspection` — repo state from `.git`**
  `GitInspection.swift` (TASK-053): read `.git/HEAD`, refs, config —
  pushed vs no-remote vs branches-differ vs worktree-unknown. No
  subprocess, no network. Same file format on Windows; direct port.

- [ ] **WIN-024: `.gitignore` oracle**
  `GitInspection`/`.gitignore` evaluator (TASK-054): nested files,
  `info/exclude`, negation, anchoring, `**`; read-only "ignored by git"
  bytes per repo. Pure-logic port, plus the indexed-by-literal-name
  prefilter that made it fast.

- [ ] **WIN-025: `CleanupRecipes` + `cleanup-recipes.json`**
  `CleanupRecipes.swift` (TASK-055): for dirs that are unsafe to Trash —
  show the tool command with a Copy button, never run it. Port the
  recipes with Windows command lines (`npm cache clean --force`,
  `pnpm store prune`, `go clean -modcache`, `docker system prune -a`,
  `dotnet nuget locals all --clear`, `pip cache purge`), and mark
  `trashIsUnsafe` for Docker Desktop `DockerDesktopWSL`/`ext4.vhdx`,
  WSL distro vhdx files — the biggest files on most dev Windows machines
  and the reason this feature exists. The cleanup queue should warn when
  a `trashIsUnsafe` path is staged from anywhere (see macOS behavior).

- [ ] **WIN-026: `FolderInsight`**
  `FolderInsight.swift` — per-folder insight lines used by the inspector
  and stories.

- [ ] **WIN-027: `StorageStories`**
  `StorageStories.swift` — the narrative sentences in Overview/cards.

- [ ] **WIN-028: `StorageHistory`**
  `StorageHistory.swift` (TASK-079): one JSON per scanned root under
  `%LOCALAPPDATA%\DiskMap\History\`, atomic rewrite, retention = last of
  each day for 30 days then last per ISO week for a year; "what grew
  this week" comparison (≥100 MB growers, parent/child dedup rule,
  matching-basis-only comparisons). Feeds Overview card + tray line.

- [ ] **WIN-029: `SavedSearch`**
  `SavedSearch.swift` (TASK-081): JSON in preferences, max 20, live size
  per saved search after each scan (one count-only `FileQuery` pass,
  off the UI thread). Needs WIN-016 first.

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

- [ ] **WIN-030: Sidebar grouped into sections + Overview page**
  New `Pages/OverviewPage.cs` — volume card (WIN-005/WIN-014), category
  breakdown (home / whole-disk / folder modes from `CategoryMode.detect`
  — folder mode splits by file type), segmented bar, "what grew this
  week" (WIN-028), unreadable-dirs banner (WIN-003), story line
  (WIN-027). It's the first destination and the only one not requiring
  a scan.

- [ ] **WIN-031: Incremental rescan (USN journal)**
  macOS: TASK-061 — FSEvents id recorded before the walk; replay events
  since, re-list touched folders and parents, spot-check 64 unchanged
  folders, fall back to full walk with a reason on: no baseline, wrapped
  ids, >20k changed folders, root moved, or a spot-check disagreement.
  Windows equivalent: USN journal (`FSCTL_READ_USN_JOURNAL`, or
  `FSCTL_ENUM_USN_DATA` seeding) — record `JournalId`+`NextUsn` before
  the scan, replay `USN_RECORD`s on rescan. Persist tree + baseline to a
  `%LOCALAPPDATA%\DiskMap\ScanCache` slot (snapshot codec exists).
  Fallbacks: journal wrapped (`UsnJournalID` changed / records
  overwritten), non-NTFS, walk-backend scan (no record coverage), change
  flood. This is the ticket that makes rescan ~200 ms vs seconds — and
  WIN-013's change check. Biggest single feature; own milestone.

- [ ] **WIN-032: Find page + filter chips**
  `FindView.swift` (TASK-060): query box (WIN-016), sort, chips —
  Large (`size>500MB`) · Old (`age>1y`) · Duplicated (`is:duplicate`) ·
  Cached (`in:caches`) · Media (`kind:media`) · Downloads
  (`in:downloads`). Multi-select → Add to Cleanup / Reveal / Copy Paths;
  context menu Reveal / preview / Show in Visualize / Copy Path.
  `is:duplicate` explains itself and links to the Duplicates run.

- [ ] **WIN-033: Search page**
  `SearchView.swift` — find-as-you-type over `FileSearchIndex`
  (WIN-017), kind filter, ranked results, Show-in-map jump, double-tap
  reveal.

- [ ] **WIN-034: Biggest Files + Biggest Folders**
  `BiggestFilesView.swift`, `BiggestFoldersView.swift` — separate
  file-only and folder-only ranked lists with staged checkboxes, reveal,
  iCloud→OneDrive icons on not-downloaded rows. Today's Top Sizes mixes
  both; keep it as the "biggest items" list or align naming with macOS.

- [ ] **WIN-035: Forgotten Files page** — WIN-020 catalog + list + stage.

- [ ] **WIN-036: Safe to Review page** — WIN-021 catalog, why-it's-safe
  notes, per-category stage.

- [ ] **WIN-037: Caches page** — `CachesReviewView.swift` equivalent:
  cache locations review (Windows: `%LOCALAPPDATA%\Temp`,
  `INetCache`, per-app caches — decide what's in-scope; bias
  conservative).

- [ ] **WIN-038: Old Downloads page** — WIN-018 catalog + list + stage.

- [ ] **WIN-039: Large Media page** — WIN-019 catalog + list + stage.

- [ ] **WIN-040: File Browser page** — `FileBrowserView.swift`
  equivalent: browsable list with columns (name, size, modified, kind),
  drill on double-click, checkbox staging, sortable.

- [ ] **WIN-041: Developer Storage page** — WIN-022..025 catalogs:
  project list grouped by ecosystem, rebuild-cost column, git state,
  ignored-bytes line, recipes with Copy, aging headline, per-category
  Stage All. The page macOS built Developer Storage v2 for; on Windows
  this is likely the highest-value single screen (dev machines are where
  the disk fills).

- [ ] **WIN-042: Regenerable Data page** — already ~covered by the
  categorized Quick Wins page; the remaining delta is per-category
  "why it's safe" notes and the dedicated sidebar slot. Decide: fold
  into Quick Wins page (rename it) or split like macOS.

- [ ] **WIN-043: Applications page parity check** — registry listing
  exists; macOS adds bundle size + per-leftover sizes + staged group.
  Windows gaps: MSIX/Store apps (`Get-AppxPackage` equivalent via
  Package Manager API, no subprocess), per-app total footprint (install
  dir + leftovers summed), uninstall string reveal. Mark partial.

- [ ] **WIN-044: Snapshot compare v2**
  `SnapshotComparison.swift` + `SnapshotCompareView.swift` (TASK-071):
  lazy tree alignment by name (not full-path dictionary — O(subtree)
  setup), net change with before/after bars, grew/freed split, volume
  free-space change, hotspot story, breadcrumb drill-down where rows
  sum to their folder. Current flat path diff repeats one change at
  every ancestor — the exact bug the rewrite fixed.

- [ ] **WIN-045: Interactive Age Map** — click a bucket bar to filter
  the file list to that age band (`AgeMap.Files` equivalent); click
  again/Clear to revert to Untouched. One-list addition.

- [ ] **WIN-046: Cloud icons on not-downloaded rows** — `NotDownloaded`
  is stored; no list renders it. macOS: iCloud glyph on file rows in
  Folders/Top Sizes/Age Map/Search. Windows: OneDrive cloud glyph or a
  text badge — anywhere `Explorer.Reveal` would recall content, show it.

---

## 5. Visualize shell & inspector — P1/P2

macOS folded all 8 modes into one **Visualize** destination with shared
chrome (`ExploreShellView`, `LayoutChartView`, `ExploreColoring`):
view-mode picker, depth slider, coloring modes, and an inspector column.
Windows kept each mode as its own sidebar page — fine as an incremental
state, but the inspector and coloring layers are missing entirely.

- [ ] **WIN-047: Inspector panel** — the right column in Explore:
  DETAILS (name, kind, created — needs WIN-001's createdDay — modified,
  logical vs on-disk, "Compressed by = logical − on disk"), Largest
  Inside (top-N children), actions: Reveal / preview / Focus (drill) /
  Copy Path / Add to Cleanup; selection sync from every chart and list.

- [ ] **WIN-048: Coloring modes (folder / type / age) + depth slider**
  `ExploreColoring.swift` — three palettes over the same slices;
  `depth → otherFraction` (currently `ChartLayout.OtherFraction` is a
  hardcoded 0.005 const — make it a parameter). Type coloring needs
  WIN-015.

- [ ] **WIN-049: Mind map v2 labels** (TASK-070) — own 0.5% threshold,
  real folder total + item count, "+N more · X GB — open" card,
  connectors from measured frames. Port the label/hide logic, not just
  the layout.

- [ ] **WIN-050: Chart chrome polish** — `ChartChrome.swift`/
  `ChartAccessibility.swift`: labels sized to slices, legends, empty
  states, the 60-biggest-items accessible-list behavior (see WIN-061
  for the UIA side).

---

## 6. Cross-cutting UX — P2

- [ ] **WIN-051: Keyboard system** — `Keyboard.swift` (TASK-062): one
  shared list-navigation behavior (Up/Down or j/k, Enter = reveal/open,
  Delete or Ctrl+Backspace = stage via each list's own path, Space =
  preview), destination shortcuts (Ctrl+1–9), Ctrl+R rescan,
  Ctrl+Shift+R full rescan, Ctrl+Down/Up drill. WPF: one attached
  behavior in `Mvvm.cs` style + `Window.InputBindings`.

- [ ] **WIN-052: Multi-selection** — `MultiSelection.swift` (TASK-074):
  Ctrl+click add/remove, Shift+click range, plain click reset; shared
  toolbar (count, bytes counting a folder and its contents once,
  Add to Cleanup, Reveal, Copy Paths, Clear); Ctrl+A/Esc in checkbox
  lists. Applies to every chart control and list page.

- [ ] **WIN-053: Command palette** — `CommandPalette.swift` (TASK-059):
  Ctrl+K (the ⌘K equivalent): query shows its meaning, top-8 hits with
  sizes, "Show all in Find", plain words search names via the same
  engine, lists saved searches. Needs WIN-016/017.

- [ ] **WIN-054: Copy Paths + Export scan**
  `ExportScan.swift`, `TreeExport.swift` (TASK-058): JSON (nested),
  NDJSON, RFC 4180 CSV, ncdu `-o` format (whole tree; `asize`/`dsize`,
  link fields); "Copy Paths" (one per line, shell-quote only when
  needed — quote rules differ: cmd/PowerShell quoting, not `sh`).
  `TreeExporter` port is pure logic; wire to a File menu (WIN-056) and
  the multi-select toolbar.

- [ ] **WIN-055: Drag-to-scan + command-line arg** — `DropToScan.swift`
  (TASK-063): drop a folder on the window (dashed highlight; refuse
  files with a hint), accept a path argv on launch, optional Explorer
  "Scan with DiskMap" context-menu verb (registry/MSIX
  `windows.fileTypeAssociation` — decide; never become default opener).

- [ ] **WIN-056: Menu bar / window chrome** — WPF has no menu today.
  File menu: Scan Folder…, Rescan (quick/full), Export Scan…, Put Back
  Last Cleanup, Exit. Go: destinations. View: Appearance, Text Size.
  Also the staging toast affordance macOS shows on every stage.

- [ ] **WIN-057: Tray icon (menu-bar-extra counterpart)** —
  `MenuBarStatus.swift` (TASK-064): free space (warning under 10%),
  change since last scan (±50 MB = "about the same"), last scan
  folder/size/age, stale-project line once Developer Storage exists,
  one-click quick rescan, Open DiskMap. Strictly passive — one
  `GetDiskFreeSpaceEx` poll on a timer, no background scanning.
  WPF `NotifyIcon` (needs a Forms reference or a small interop wrapper).

- [ ] **WIN-058: Appearance + dark mode** — macOS Milestone 10
  (semantic tokens, adaptive palettes, System/Light/Dark). WPF:
  `Theme.cs` is the single palette holder today — restructure as
  theme dictionaries (Light.xaml/Dark.xaml), follow
  `AppsUseLightTheme` registry + `WM_SETTINGCHANGE`, add the
  System/Light/Dark picker (persist in settings). The dark-mode chart
  traps macOS hit — translucent fills darkening over dark canvas,
  light `ink` text on pastel tiles — apply to `NodeColors`/control
  rendering; make tiles opaque like `DiskMapTheme.wash` did.

- [ ] **WIN-059: Text size scaling** — `TextSize` (TASK-085): 0.9/1.0/
  1.15/1.3 driving a type scale + sidebar width. Windows: one scale
  factor resource; adopt named `FontSize` tokens in `Theme.cs` instead
  of literal sizes, then scale them.

- [ ] **WIN-060: Settings window** — `SettingsView.swift` (⌘,): clone
  accounting toggle, history retention, appearance, text size,
  updates. Windows: clone accounting lands with WIN-066; history with
  WIN-028; appearance with WIN-058. Create the window when the first
  setting exists; persist to `%APPDATA%\DiskMap\settings.json`.

- [ ] **WIN-061: Accessibility** — `ChartAccessibility.swift` +
  `.rowActions` (TASK-078/085): rows as real buttons with
  selected-state, chart shapes exposed as items ("name, size, share",
  "Open" action for folders), keyboard chart navigation
  (`ChartNavigation`). Windows: `AutomationProperties.Name`/`UIA`
  peers on chart controls, focusable charts + arrow-key nav, Narrator
  pass on every page.

- [ ] **WIN-062: Quick Look counterpart** — no Windows equivalent
  that's embeddable. Options: Explorer preview pane isn't hostable;
  `IPreviewHandler` can be hosted (complex); simplest honest answer is
  keeping Reveal + adding a file-properties/details pane in the
  inspector (WIN-047). Decide when inspector lands; don't fake it with
  a custom previewer.

- [ ] **WIN-063: First-run hero + toasts** — `FirstScanHero.swift`,
  `SharedChrome.swift` toast system: empty state that teaches
  scan→explore→stage, transient confirmations for stage/commit/
  put-back/export.

- [ ] **WIN-064: Rescan button + short-window scrolling** —
  `ContentView` rescan affordance; TASK-072's below-720pt page-scroll
  rule. Windows: ScrollViewers exist per page; verify a 600px-tall
  window still reaches every control.

- [ ] **WIN-065: Saved searches sidebar** — WIN-029 + UI: "Saved"
  section under Find (outside numbered shortcuts), live size per
  search, Rename/Move/Remove, starter suggestions in Find's empty
  state, palette listing.

---

## 7. Correctness & accounting extras — P1/P2

- [ ] **WIN-066: Clone-aware totals (ReFS), opt-in** — TASK-077:
  walk reads sharing facts into a sorted side table; allocated rollups
  charge each family once at the electee, private bytes elsewhere;
  Overview line "N cloned copies in M groups share X … counted once".
  Windows reality: only ReFS (Dev Drive) has block clones; on NTFS the
  clone family is the hard-link set (WIN-002 already covers it). Scope:
  on ReFS roots, `FSCTL_GET_RETRIEVAL_POINTERS` during scan is too
  heavy — measure first (macOS gated at +14% and shipped it off by
  default). Likely implementation: reuse the MFT path's cheap signals +
  an extent-compare pass only on size-colliding files, or document
  "ReFS clones counted per copy" as a known limitation and skip.
  Measurement decides; settings toggle either way.

- [ ] **WIN-067: Snapshot codec convergence** — Windows writes/reads
  DMAP **v1**; macOS is now at **v4** (v3 fileID, v4 sharing table +
  sharing mode). `windows/README.md`'s "files are interchangeable" is
  stale. Decide: (a) track macOS codec versions — needed if a shared
  snapshot dir or the CLI interchange matters; (b) document the fork
  and bump a Windows-side `DMAP` minor with the WIN-001 fields.
  Either way, add a forward-version read path so a macOS v3/v4 file
  decodes instead of throwing `BadVersion` — v1/v2-style compat read
  is the established pattern.

- [ ] **WIN-068: Fresh-clone correctness check** — TASK-067's bug
  (clone reported identical before writeback flush) is APFS-specific,
  but the Windows path has its own version: MFT `$DATA` sizes vs
  actual content, USN-lagged records. Verify: `cp`-equivalent clone
  (ReFS `FSCTL_DUPLICATE_EXTENTS_TO_FILE`) edited then scanned —
  `AreLikelyClones` must say no, content hash must run. Port the
  fixture test pattern (`fsync`-equivalent: `FlushFileBuffers`).

- [ ] **WIN-069: Excluded-paths review pass** — current list covers
  OS roots. Audit against: `%LOCALAPPDATA%\Microsoft\WindowsApps`
  (reparse-point-heavy), `WinSxS` (hard links — scanning OK, staging
  must stay refused via `C:\Windows` prefix — verify the component
  store can't be offered), `pagefile`/`hiberfil`/`swapfile` (not
  walkable anyway), user-profile junctions. Call out any change in the
  summary, per the rule.

---

## 8. CLI & export — P2

- [ ] **WIN-070: `diskmap` CLI** — TASK-057: new console project
  `windows/app/DiskMap.Cli` depending only on DiskMap.Core. Commands:
  `scan --json`, `find <path> <query>` (WIN-016), `dup`, `dev
  --reclaimable --older-than 6m`, `check --fail-over 50GB`, `export`.
  Exit codes: 0 ok / 1 check-over / 2 usage / 3 unreadable. Sizes SI
  (`50GB` = 50·10⁹; `GiB` = 1024³), ages `30d/2w/6m/1y`, progress to
  stderr only on a terminal so `--json` stdout is clean — same
  contract as macOS so scripts port.

- [ ] **WIN-071: Bench harness** — `DiskMapScanBench` equivalent:
  `--repeat/--rollup/--json/--phases/--label` runs feeding a
  `docs/perf-results/` trail, like `docs/PERF.md` on macOS. Needed to
  gate WIN-066 and to track MFT vs walk regressions. Cheap: the timing
  points already exist in `ScanEngine`.

---

## 9. Packaging & distribution — P2

- [ ] **WIN-072: Elevation UX decision** — `app.manifest` is
  `requireAdministrator`: UAC at every launch just to scan a home
  folder. macOS asks for nothing until Full Disk Access is needed.
  Consider `asInvoker` default + on-demand MFT elevation (elevate only
  when the user picks a drive root and wants the fast path — a
  `runas` self-relaunch or an elevated helper), keeping the walk for
  unelevated use. Product call; today's choice makes every casual scan
  pay a UAC prompt.

- [ ] **WIN-073: Packaging** — MSIX (store-ready identity, context-menu
  verb for WIN-055, clean uninstall) vs portable zip + Inno/WiX
  installer. Icon: port `Resources/AppIcon` concept to a `.ico`
  (already a placeholder `app.ico`). Version scheme mirroring
  `VERSION` + git build number.

- [ ] **WIN-074: Update mechanism decision** — macOS: Sparkle, opt-in,
  the single networking exception. Windows: decide early whether the
  answer is MSIX auto-update, a Velopack/Squirrel-style feed under the
  same opt-in rule, or no updater (offline-purist default, manual
  download). Whatever ships, it's the only file allowed to touch the
  network — same `NetworkPolicyTests`-style guard wanted.

---

## 10. Windows-only opportunities (beyond parity)

Not required for parity, but structural advantages the platform gives —
same spirit as the macOS "do better" list. Track here so they aren't lost.

- [ ] **WIN-075: WSL/VHD awareness** — `ext4.vhdx`, `DockerDesktopWSL`
  dirs: flag in Developer Storage + a `trashIsUnsafe`-style warning
  (deleting a distro vhdx destroys the distro — the Windows Docker.raw).
- [ ] **WIN-076: NTFS compression / compactOS surface** —
  `GetCompressedFileSizeW` already feeds allocated size; an "NTFS-
  compressible" insight (files where compact would reclaim X) is a
  Windows-only lever the macOS app can't have. Show, never run — the
  same recipe philosophy as WIN-025.
- [ ] **WIN-077: OneDrive Files On-Demand depth** — pin-status
  (`FILE_ATTRIBUTE_PINNED`/`UNPINNED`) could power a "freeable cloud
  space" view (evict, not delete — different action, outside
  CleanupQueue; a recipe-style "show don't run" candidate).
- [ ] **WIN-078: Storage Sense / previous-versions reconciliation** —
  VSS usage (`vssadmin`-equivalent via WMI, read-only) explaining the
  WIN-005 gap concretely instead of hand-waving "system files".

---

## 11. Tests & tooling

- [ ] **WIN-079: Port feature tests as features land** — macOS is at
  ~305 tests; Windows ~41. Every ticket above names its macOS test
  file; port the fixture style (real temp dirs, real `CreateHardLinkW`,
  never mocks for filesystem behavior).
- [ ] **WIN-080: Visual/snapshot harness** — macOS `SnapshotHarness`
  renders the real window to PNG in-process for review and CI visual
  diffs. WPF equivalent: `RenderTargetBitmap` per page + golden compare
  (optional; even render-to-file for eyeballing pays off).
- [ ] **WIN-081: Keep `windows/README.md` "What maps to what" current**
  — it's the API-mapping cheat sheet (getattrlistbulk→FindFirstFileExW,
  F_LOG2PHYS_EXT→retrieval pointers, trashItem→SHFileOperation). Every
  P0/P1 ticket that adds a mapping should extend the table, and fix the
  stale "snapshots interchangeable" claim under WIN-067.

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
