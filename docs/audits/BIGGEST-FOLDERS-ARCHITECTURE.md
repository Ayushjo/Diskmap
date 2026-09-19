# Biggest Folders — architecture audit (2026-09-14)

Branch context: continue from `feat/redesign-biggest-files` (or cut `feat/redesign-biggest-folders` from it).
Biggest Files quality bar: `BiggestFilesView` + `FileInspectorPanel`.

## Current implementation

| Piece | Today |
|-------|--------|
| Route | `AppDestination.biggestFolders` → `FoldersView` inside `findWrapper` |
| Navigation | `DrillHeader` / `BreadcrumbBar` jump → sets `currentNode` |
| Rows | Immediate children of `currentNode`, sorted by rolled-up `totals` |
| Click | **Select + drill in one click** if directory (`selectedNode` + `currentNode = id`) |
| Inspector | **None** — page is list-only |
| Progress bars | Per-row `ProportionBar` vs parent total |
| Empty / 0 KB noise | Shows all children with size; empty message only if no sized children |
| Scanner | Untouched; uses existing `selectedTotals` |

## Reusable building blocks (do not reinvent)

Already exist — use them:

1. **`FileTree.children(of:totals:)`** — immediate children with sizes (correct hierarchy model).
2. **`ScanModel.descendantFileCounts` / `descendantFolderCounts`** — already computed once post-scan via `rollUpDescendantCounts()`.
3. **`SafetyClassifier.assess(path:name:isDirectory:)`** — folder-aware rules (Downloads, Library, Docker, System, caches…).
4. **`CleanupQueue.stage` + `CleanupPreflight`** — Trash-first review queue; wording should be “Review in Cleanup / Add to cleanup review”, not physical move.
5. **`FileTypeCatalog`** — extension→category; today `totals(in:tree:)` is **whole-tree**. Need a **subtree** variant for composition.
6. **`CanonicalPath.displayPath` / `parentDisplay`** — user-facing paths.
7. **`AgeMap.untouched`** — can estimate “potentially reviewable” under a folder (old files only; honest language).
8. **Biggest Files patterns** — select vs action, full-width inspector buttons, empty inspector copy.

## Gaps (smallest fixes)

### A. Interaction model (UI-only, high leverage)

`FoldersView` today drills on every directory click.

**Change:**
- Single click → `selectedNode = id` only.
- Chevron / Open / double-click → `currentNode = id` (drill).
- Keep `DrillHeader` breadcrumbs for jump/back; add explicit ‹ Back (`parent[currentNode]`).

No scanner changes.

### B. Folder as first-class object + inspector (UI + thin core helper)

Mirror Biggest Files layout: list | inspector (~320pt).

Inspector inputs all derivable from existing scan:

| Field | Source |
|-------|--------|
| Name / path / size | `FileTree` + `totals` + `CanonicalPath` |
| Item counts | `descendantFileCounts[id]` / `descendantFolderCounts[id]` |
| Composition | New: `FileTypeCatalog.totals(under:nodeID,…)` walk descendants once (or memoize per selection) |
| Safety | `SafetyClassifier.assess(..., isDirectory: true)` |
| Why large | Template from composition + safety (deterministic; no invented facts) |
| Reviewable estimate | Sum of `AgeMap.untouched` / known-safe child bytes **under** node, capped; label “Potentially reviewable”, never “recoverable” |
| Actions | Safety-gated: Review in Cleanup / Open Finder / Copy path / (no recursive delete CTA) |

### C. Composition API (small DiskMapCore addition)

```text
FileTypeCatalog.totals(under nodeID, in tree, sizes, categories) -> [FileTypeTotals]
```

Walk only the subtree (DFS/BFS via firstChild/nextSibling). Same categories JSON. **No scanner rewrite.**

Optional: `FolderInsight` struct assembling size/counts/composition/safety/reviewable for tests.

### D. Root noise filter (UI policy, not hard exclude from model)

At `currentNode == 0` when scan root is `/`:

- Default hide zero-size children and known technical stubs (`.vol`, `.file`, `cores`, `dev`, `bin`, `sbin`, …) behind “Show technical folders”.
- Still show meaningful large areas: Users, System, Applications, Library, private, opt, …

Do **not** hide large System storage; classify it Protected / no cleanup.

### E. Cleanup integration (reuse queue)

- Eligible folders: `cleanupQueue.stage(folderURL, size: totals[id], reason: "Biggest folder: …")` then open cleanup sheet / toast “Added to cleanup review”.
- Protected / managed (Docker, System): **no** stage button; show explanation + Open in Finder (+ optional Learn more URL later).
- Do not implement one-click recursive delete on this page.

### F. Cross-link Biggest Files (light)

Inspector: top 5 files under folder via local file walk of subtree + `View all files →` sets destination `.biggestFiles` with a path filter (add `@Published folderFilterPath: String?` on `ScanModel` or pass via destination state). Smallest path: set `query`/`pathPrefix` on model that Biggest Files already filters.

### G. Preserve Explore Folders mode

`exploreMode == .folders` still uses `FoldersView` / chart drill. Prefer:

- New `BiggestFoldersView` for Find → Biggest Folders (selection + inspector).
- Leave Explore’s folder browser as-is or share row styling later.

Avoid breaking Visualize.

## Explicit non-goals this iteration

- Scanner / BulkScan / firmlink rewrite (already on biggest-files branch).
- Treemap/sunburst inside Biggest Folders.
- Speculative “Most reviewable” sort until reviewable metric is tested.
- Recursive “Delete folder” without confirmation flow (defer; Cleanup remains the destructive surface).

## Implementation order (when coding starts)

1. Cut branch `feat/redesign-biggest-folders` from current tip.
2. Core: subtree `FileTypeCatalog.totals(under:)` + optional `FolderInsight` + tests.
3. UI: `BiggestFoldersView` — select vs drill, header/back/breadcrumbs, row chrome, hide 0KB noise.
4. `FolderInspectorPanel` — composition, safety actions, cleanup stage, Finder/copy.
5. Wire AppShell; optional path filter → Biggest Files.
6. `swift test`, ad-hoc app, push PR.

## Risk notes

- Composition walk on huge folders must be capped/time-bounded or memoized per `selectedNode` so inspector stays snappy (data already in memory; walk is pointer chase, not disk I/O).
- Staging an entire Downloads folder is powerful — UI copy must say review queue, and Cleanup should still list the folder as one staged item (current queue model supports that).

## Definition of success (product)

Select Downloads → inspector explains composition + potentially reviewable + Review in Cleanup.  
Select System → protected, no cleanup.  
Select Docker path → managed warning.  
Drill via chevron only; hierarchy stays immediate-children-only.
