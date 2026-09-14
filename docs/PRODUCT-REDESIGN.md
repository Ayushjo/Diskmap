# DiskMap product redesign

**Branch:** `feature/product-redesign` (forked from `perf/scan-and-runtime`; do not destroy the perf branch).

**Behavior source of truth:** [OSS_Disk_Analyzer_Product_Specification.md](reference/OSS_Disk_Analyzer_Product_Specification.md)

**Visual direction:** [DiskMap1.png](reference/DiskMap1.png) (Explore), [DiskMap2.png](reference/DiskMap2.png) (Overview). DiskBuddy images in `docs/reference/` are competitive references only.

**Philosophy:** DiskBuddy shows storage. DiskMap helps the user understand it.

## Hard constraints

- Preserve BulkScan / FileTree / rollups / existing visualizations / tests / perf work.
- Redesign product experience and IA (Overview → Find → Clean → Explore), not a greenfield rewrite.
- Deterministic analysis for sizes and safety; AI (if any) only phrases structured facts.
- Cleanup is review-first; prefer Trash; never silent delete.

## Implementation order

See Notion: *Implementation Plan: DiskMap Product Redesign* (and prompt phases 0–18).

0. Audit + this branch  
1. Design system + shell  
2. Overview  
3. Inspector + breadcrumbs  
4. Biggest files/folders  
5. Folder explorer  
6. Treemap  
7. Other visualizations  
8. Forgotten files  
9. Safety engine  
10. Cleanup workflows  
11. Duplicates  
12. Developer storage  
13. Stories / recommendations  
14. Explain My Storage  
15. ⌘K / search  
16. Accessibility  
17. Perf regression  
18. Polish  

## Baseline (Phase 0)

- Tip at branch cut: see `git log -1 --oneline` on this branch.
- Engine: `Sources/DiskMapCore/{BulkScan,FileTree,ScanEngine}.swift`
- UI shell today: Explore-first in `ExploreShellView.swift` (to be re-homed under task IA).
