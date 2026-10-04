# DiskMap product redesign — implementation audit

**Date:** 2026-09-15  
**Base inspected:** `perf/scan-and-runtime` (`495bdc2`) + stacked redesign tip `feat/redesign-large-media` (`d654512`)  
**Working branch:** `feat/diskmap-product-redesign` (cut from Large Media tip — **not** a rewrite of `perf`)  
**Do not touch:** `perf/scan-and-runtime` directly

---

## 1. Current architecture

| Layer | Role |
|-------|------|
| `DiskMapCore` | Headless: `ScanEngine`/`BulkScan`, `FileTree` (SoA), `CanonicalPath`, catalogs, safety, duplicates/clones, `CleanupQueue`, snapshots, viz math |
| `DiskMapApp` | SwiftUI shell: `AppShellView`, `ScanModel` (`ContentView.swift`), per-destination views, `DesignSystem`, ⌘K `CommandPalette` |
| Build | SPM `Package.swift`, macOS 14+, ad-hoc `scripts/build-adhoc.sh` → `dist/DiskMap.app` |
| Tests | `Tests/DiskMapCoreTests` (~96 tests at Large Media tip) |

**State:** single `ScanModel` owns tree, totals (logical/allocated), destination, selection, staged cleanup mirror, per-feature caches (Forgotten, Reviewables, Developer, Old Downloads, Large Media).

**IA (matches product sidebar):** MAIN → FIND → CLEAN → EXPLORE via `AppDestination` / `AppNavSection`.

---

## 2. Current reusable components

**Exist (partial):** `DiskMapTheme`, `DiskMapType`, `PanelCard`, `StatRow`, `ProportionBar`, `InkButtonStyle`, `PrimaryCTAStyle`, `SectionLabel`, volume card in shell, ⌘K palette, Cleanup sheet.

**Missing / duplicated (gap):** one shared `Inspector` / `FileRow` / `FolderRow` / `FilterBar` / `SelectionToolbar` / `EmptyState` / `LoadingState` / `ClassificationBadge` — each redesigned page reimplements variants. Global selection (Cmd/Shift) is not one model.

---

## 3. Current page structure (tip vs perf)

| Page | On tip (`feat/redesign-large-media`) | vs this spec |
|------|--------------------------------------|--------------|
| Overview | Redesigned (explain + categories) | Polish density / health language |
| Biggest Files | Redesigned | Align filters/sort chrome |
| Biggest Folders | Select vs drill + inspector | Verify folder stage safety UX |
| Forgotten Files | Confidence model | Age viz + filter chips polish |
| Duplicates | Basic list + spinner | **Needs phase/cancel/error UI** (known infinite-feel bug) |
| Safe to Review | App-grouped | Align badges/footer |
| Caches | App-grouped | Density + icons polish |
| Old Downloads | Catalog + table | Matches intent |
| Large Media | MediaCatalog + workspace | Thumbnails/AV metadata = P1 |
| File Browser | Storage-aware Finder | Keyboard / responsive inspector |
| Visualize | Workspace, no 2nd sidebar | Mode tooltips, canvas dominance |
| Developer Storage | Command center | Consequence copy polish |
| Applications | Real icons + related | Grid toggle optional |
| Snapshots | History + compare | Empty/loaded polish |

Stacked open PRs #3–#14 sit on top of `perf` (~31 commits). Older `feature/product-redesign` (#2) is **behind** this tip — do not restart from it.

---

## 4. Scanner / data architecture (preserve)

- `BulkScan` + `getattrlistbulk`, multi-worker  
- `FileTree` packed SoA + name interning + `compact()`  
- iCloud: no content materialization; `notDownloaded` flags  
- Rollups: allocated + logical; `CanonicalPath` / firmlink awareness  
- Size basis toggle on `ScanModel.selectedTotals`  

**Do not rewrite** for UI redesign.

---

## 5. Cleanup architecture (preserve)

- `CleanupQueue` actor → Trash via `trashItem` only  
- Prefix denylist + `CleanupPreflight` / `SafetyClassifier`  
- Pages stage → Cleanup Review sheet → confirm  

Align UI language: **Review**, never casual Delete.

---

## 6. Visualization architecture (preserve)

- Modes under Explore/Visualize: treemap, sunburst, flame, bubbles, mind map, age, folders, top sizes  
- Layout math in Core (`SquarifiedTreemap`, `CirclePack`, `ChartLayout`, …)  
- `ExploreShellView` / `VisualizeView` share selection with tree  

Keep canvas implementations; redesign chrome only.

---

## 7. What can be reused

- Entire Core scan/tree/canonical/safety/cleanup/dup/clone/snapshot stack  
- Shell IA + destinations  
- Per-page catalogs already shipped (Forgotten, Reviewable, Developer, Applications, Old Downloads, Media, FolderInsight, …)  
- Design tokens as a starting point (extend spacing scale / inspector primitives)  
- Reference PNGs under `docs/reference/` + page audits under `docs/audits/`  
- Ad-hoc build + Swift Testing suite  

---

## 8. What needs refactoring

1. **Extract shared UI kit** — Inspector, rows, filters, selection bar, empty/loading  
2. **Unify selection model** — click / checkbox / Cmd-Shift / keyboard  
3. **Responsive inspector** — hide/slide under ~1280 width  
4. **Duplicates UX** — phases, progress text, cancel, terminal states (no silent forever spinner)  
5. **Cross-page visual QA** — density, row height ~44–56, badge language, long paths  
6. **Large Media P1** — lazy thumbnails + cheap metadata  
7. **⌘K** — deepen deterministic groups (files/folders/apps/actions)  
8. **Merge path** — squash/stack redesign PRs onto one reviewable line off `perf`  

---

## 9. What should NOT be touched

- `ScanEngine` / `BulkScan` / `FileTree` packing / home-scan perf path  
- `CloneDetector` / `DuplicateFinder` algorithms (UI only until a dedicated engine pass)  
- Direct `unlink` / bypassing CleanupQueue  
- Inventing “last opened” or “safe to delete” for personal media  
- Second scanner or non-canonical double-counting  
- Rewriting viz layout engines for style  

---

## 10. Proposed implementation plan (this branch)

**Branch policy:** `feat/diskmap-product-redesign` = consolidation + global polish on tip. Leave `perf/scan-and-runtime` intact.

| Phase | Focus | Status |
|-------|--------|--------|
| 0 | Audit + branch | **Done** |
| 1 | Design tokens + shared Empty/Loading/Badge/SelectionToolbar + Duplicates states | **Done** |
| 2 | AppShell responsive content width + cleanup reclaim badge + lower min window | **Done** |
| 3 | Biggest Files/Folders → WhyCard / SafetyCard | **Done** |
| 4 | Forgotten/Safe/Caches keep custom selection bars (Select visible / generally safe) | Deferred intentional |
| 5 | Old Downloads + Large Media SelectionToolbar, WhyCard, badges, **lazy QL thumbnails** | **Done** |
| 6 | Visualize mode blurbs + tooltips | **Done** |
| 7 | Developer WhyCard/SafetyCard; adaptive inspector widths across Explore pages | **Done** |
| 8 | Duplicates progress/cancel/error/empty | **Done** |
| 9 | Global a11y/long-name polish | Ongoing with page work |
| 10 | PR #15 onto `perf` | Open — continue commits |

**Success:** one native macOS storage-intelligence app; explain → investigate → review → Cleanup → Trash; no invented facts; scanner/runtime preserved.


## Status (2026-09-15 consolidation)

Shipped on `feat/diskmap-product-redesign` / PR #15:

- Shared chrome kit + Duplicates terminal states
- WhyCard / SafetyCard / SelectionToolbar / badges rolled through major Find/Clean/Explore pages
- Large Media Quick Look thumbnails (lazy)
- Adaptive inspector width from shell content GeometryReader
- Cleanup badge shows reclaimable bytes
- Visualize mode purpose blurbs + help

**Intentionally deferred (not blockers):** unified Cmd/Shift multi-select model across every table; pixel-perfect QA vs every reference PNG; collapsing inspector to sheet under ~980px (width scales today); Forgotten/Safe custom selection bars kept for “Select visible / generally safe”.
