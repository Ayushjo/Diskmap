# macOS fixes needed — ported back from the Windows build

The Windows port (`windows/`) picked up a batch of fixes and features in
the October 2026 performance/UX session that the macOS app doesn't have
yet. Each entry says what changed on Windows (with the file to read),
why, and what the macOS equivalent likely is. Items marked **check first**
may already be partly covered on macOS — confirm against the named Swift
file before porting.

Same rules as everywhere: `DiskMapCore` stays UI-free, every removal goes
through `CleanupQueue`, nothing touches the network, and each port needs a
Swift Testing test (`scripts/test.sh`).

---

## 1. Scanning speed

### 1.1 Save the rescan baseline off the critical path
- **Windows:** `ScanCache.SaveInBackground` (`windows/src/DiskMap.Core/ScanCache.cs`), called from `ScanEngine.ScanAsync` once the tree is final.
- **Why:** writing the ~500 MB snapshot of a full-disk tree cost ~2–2.5 s on *every* scan before results appeared. Saves now run on one chained background task; `Load`/`Remove` wait for it, so a rescan sees the newest baseline and a forced full rescan can't be undone by a late save.
- **macOS:** wherever `IncrementalScan`/the FSEvents baseline is written after a scan (`Sources/DiskMapCore/IncrementalScan.swift`, `Snapshot.swift`) — move the write to a serial background queue, and make load/remove wait on it.

### 1.2 Incremental rescan must cost O(changes), not O(tree)
- **Windows:** `IncrementalScan.TryRescan` (`windows/src/DiskMap.Core/IncrementalScan.cs`). Before: ~200 journal changes took 11–16 s on 8.4 M items — *slower than a full scan* — because it built a dictionary entry, a spec object and a name set for every node. After: lookups only for changed records and their parents; unchanged nodes are copied straight from the baseline tree in one pass; the spot-check builds name sets only for the folders it samples. Rescan 3.5 s.
- **macOS:** audit `Sources/DiskMapCore/IncrementalScan.swift` for the same per-node allocations (dictionaries keyed by every node, per-folder name sets, sorting/shuffling every node to sample).

### 1.3 Changes directly under the scan root were dropped on rescan
- **Windows:** the scanners store the root node without a file id, so journal records whose parent *is* the root were never placed: new files there vanished, modified ones kept stale sizes. Fix: resolve the root's real id from disk. Test: `IncrementalScanTests.RescanAppliesCreatesAndDeletesFromTheJournal`.
- **macOS:** **check first** — does the FSEvents replay handle events whose parent is the scan root itself? Add the same test (create, modify and delete files directly in the root, then rescan).

---

## 2. Cleanup / Recycle Bin (macOS: Trash)

### 2.1 Batch and parallelize moves
- **Windows:** `Shell32.RecycleItemsParallel` + `CleanupQueue.Commit`. One shell call per item cost an engine spin-up each (500 files: 11.5 s → 2.7 s batched); folders recycle in parallel (6 × 8k-file `node_modules`: 12.9 s → 5.6 s).
- **macOS:** `FileManager.trashItem` per item in `CleanupQueue.swift` — measure a commit of a few hundred files and several large `node_modules`; parallelize folder moves on a bounded concurrent queue if it's slow.

### 2.2 Don't re-read the whole Trash to write the Put Back record
- **Windows:** `RecycleBinStore.ResolveAll` / `Resolve` (`windows/src/DiskMap.Core/PutBack.cs`) read every bin record once *per item*; now once per volume, filtered to records created since the commit started, and single lookups stop at the newest match (one test went 30 s → <1 s).
- **macOS:** `trashItem` returns the resulting URL, so this is probably fine — **check first** that `PutBack.swift` never enumerates `~/.Trash` per item.

### 2.3 Commit shows progress and never looks stuck
- **Windows:** `CleanupQueue.Commit(IProgress<CommitProgress>)` reports "Verifying sizes… n of N" then "Moving… n of N"; the Cleanup page pins a progress bar and locks while working. The commit button is no longer disabled while sizes are still being measured — committing finishes measurement itself, with progress. Size verification runs up to 8 walks at once (was 2).
- **macOS:** `CleanupQueueView.swift` — same: progress during commit, don't block the button on background measurement, raise measurement concurrency.

### 2.4 Items the bin can't hold
- **Windows:** when the Recycle Bin refuses an item (bigger than the bin's size limit), the shell used to pop a per-item "permanently delete?" box. Now `Shell32.RecycleOnlySink` vetoes that fallback (verified: no partial delete, no dialog), the item stays staged with the reason, and **one** dialog offers to permanently delete only the *regenerable* refusals (`CleanupQueue.IsRegenerable` → `DeletePermanently`). This is the documented single exception to rule #1 (see `AGENTS.md`).
- **macOS:** `trashItem` fails rather than prompting (e.g. volumes without a Trash) — make sure those failures stay staged with a readable reason. Whether to offer the regenerable-only permanent delete on macOS is a **maintainer decision**; if yes, it needs the same AGENTS.md exception and policy test.

---

## 3. Categorization and safety

### 3.1 Preconfigured storage categories
- **Windows:** `StorageClassifier` (`windows/src/DiskMap.Core/StorageClassifier.cs`, tests in `StorageClassifierTests.cs`) — one exclusive pass over the tree with ordered path rules: claim rules take a subtree, area rules set a default and keep descending (so `Documents/codes/app/node_modules` is still *Dependencies*). 18 categories: code & projects, dependencies & builds, dev tools & SDKs, package caches, WSL/Docker/VMs, AI models, documents, media, downloads, installers, cloud folders, games, browser data, installed apps, app data, caches, system, other. Overview's "Where it's going" uses it — before, a full-disk scan showed "Personal 670 GB / Developer 4 GB" because only the root's direct children were categorized.
- **macOS:** **check first** `SafetyClassification.swift`, `AnalysisSnapshot.swift`. Port the rule table with macOS paths: `~/Library/Containers/com.docker.docker/.../Docker.raw`, OrbStack, UTM/Parallels/VMware VMs, `~/Library/Developer/Xcode/DerivedData`, `iOS DeviceSupport`, CoreSimulator, `~/.ollama`, `~/.cache/huggingface`, `~/Library/Caches`, browser profiles under `~/Library/Application Support`, `/Applications`, `/System`.

### 3.2 Risky items warn before staging
- **Windows:** `ScanModel.Stage` refuses OS-managed items (with the right setting to use instead) and asks before risky ones (WSL `ext4.vhdx`, Docker's disk, emulators, installed apps, browser profiles, `.git`) with a dialog naming the safe alternative (`wsl --unregister`, `docker system prune`). Bulk adds skip risky items and say so. Lists show a ⚠ category badge with the reason as a tooltip.
- **macOS:** **check first** — the Docker.raw / VM bundles / Xcode archives equivalents. Bulk "Add Selected" must not silently stage them.

### 3.3 Never report what's already in the Trash
- **Windows:** `DeveloperCatalog` and `QuickWins` counted `node_modules` sitting inside `$Recycle.Bin` as developer storage (28 GB). Skipped via `StorageClassifier.IsSystemHolding`.
- **macOS:** make sure a scan of `/` or `~` never reports findings inside `~/.Trash` / `/.Trashes`.

### 3.4 Nested developer hits double-counted
- **Windows:** `Android` and `Android/Sdk` both matched with equal size; with an unstable size sort the child could be kept first, so 19 GB counted twice. Ties now break outermost-first (`DeveloperCatalog.Build`).
- **macOS:** **check first** `DeveloperCatalog.swift` — same "prefer outer hit" logic; make the sort tie-break on path depth.

---

## 4. UX

### 4.1 Selection bar pinned to the window, on every list
- **Windows:** `ListPage.SelectionBar` — "Select all N · n selected · size · Add N to Cleanup" docked under the scroll area on Biggest Files/Folders, Forgotten, Large Media, Old Downloads, Find, Caches, Developer Storage, Duplicates. Before, it sat after the last of up to 500 rows.
- **macOS:** Select all exists on several views (`BiggestFilesView`, `AppsView`, `AgeMapView`…) — **check first** that every list has it and that the action bar stays visible while scrolling.

### 4.2 Bulk adds confirm with full paths
- **Windows:** `ScanModel.ConfirmStageMany` + `Dialogs.Confirm` — every bulk add lists each item by full path and size, totals it, defaults to Cancel, and says nothing is deleted until the Cleanup page. The final "Move to Recycle Bin" confirmation lists everything that will move.
- **macOS:** add the equivalent sheet before bulk staging and before commit.

### 4.3 Developer Storage: "Where it lives"
- **Windows:** `DeveloperStoragePage` — folders ranked by developer bytes (auto-starts where one folder stops holding 80%+), click to drill in, **Clean** per folder and **Clean up <folder>** for the current one; the locations list follows the folder. Projects show their full path with Reveal and the exact folders "Add reclaimable" would send.
- **macOS:** port to the Developer Storage view; the folder roll-up is a few lines over the catalog items.

### 4.4 Duplicates checkboxes
- **Windows:** the per-copy checkboxes did nothing; now extra copies start ticked and the pinned bar adds the ticked set in one go (group-aware).
- **macOS:** **check first** the duplicates view.

### 4.5 Category views in lists
- **Windows:** Biggest Files/Folders etc. have a Category column and category filter pills (top 7 + "N more categories…"); Overview category rows open the list pre-filtered.
- **macOS:** add once 3.1 lands.

---

## Windows-only (no macOS action)

- Custom ScrollBar template was missing `IsDirectionReversed` (thumb ran backwards).
- Tray flyout styled like the app; the ☰ window menu removed (macOS has the real menu bar).
- MFT/USN-specific scanning details.

---

## Mac port status (2026-10-06, branch `feat/mac-from-windows`)

| Item | Status on macOS |
|---|---|
| 1.1 Save baseline off the critical path | Already so (background, chained saves). A quick rescan with no in-memory tree now waits for an in-flight save before reading the cache. |
| 1.2 Incremental rescan O(changes) | Measured: quick 3.4 s vs full 12.0 s on 2.68 M items (28%). Not a problem here; no rewrite. `docs/perf-results/mac-from-windows.txt`. |
| 1.3 Changes directly under the root | Already handled; pinned by `IncrementalScanTests.changesDirectlyInTheRootAreApplied`. |
| 2.1 Batch/parallel moves | Measured: `trashItem` is a rename (0.6 ms/file, 3 ms for an 8k-file folder) — no batching needed. The moved-with-its-folder check is now a set lookup (was O(n²)). |
| 2.2 Put Back re-reading the Trash | Not applicable: `trashItem` returns the new URL; the Trash is never listed. |
| 2.3 Commit progress | Done: "Verifying sizes… / Moving… n of N", button no longer waits on measuring, sheet locked mid-commit, measuring capped at 8 walks. |
| 2.4 Items the bin refuses | Done: stay staged with a plain reason. **Maintainer decision: no permanent delete on macOS** (AGENTS.md rule 1 unchanged). |
| 3.1 Storage categories | Done: `StorageClassifier` + `storage-categories.json` (18 categories, claims/areas/file rules, project markers). Overview, Biggest Files/Folders. |
| 3.2 Risky items warn | Done: verdicts with note + "instead"; single adds ask, bulk adds skip, macOS-managed refused. |
| 3.3 Never report the Trash | Done for every finding catalog (Overview's biggest files/folders still show a full Trash — real usage). |
| 3.4 Nested developer hits | Done: depth tie-break, outer first. Also: packages inside tool caches/app support are no longer projects (Yarn's cache made 332). |
| 4.1 Selection bar everywhere | Done: tri-state Select all on every list, pinned action bar from one selected row, ⌘A matches the box. |
| 4.2 Bulk adds confirm with paths | Done, as on Windows; Move to Trash lists everything too. |
| 4.3 Where it lives | Done: first tab of Developer Storage; Projects can add their reclaimable folders. |
| 4.4 Duplicates checkboxes | Done: extra copies pre-ticked (oldest kept), labels fixed ("newest" was wrong). |
| 4.5 Category views | Done in Biggest Files (column + pills) and Biggest Folders (label); Overview rows route there. |
