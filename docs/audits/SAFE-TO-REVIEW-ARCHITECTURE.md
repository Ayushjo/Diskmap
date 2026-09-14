# Safe to Review / Caches — architecture (2026-09-14)

Branch: `feat/redesign-safe-to-review`
UI ref: `docs/reference/DiskMap-SafeToReview.png` (Caches drill)

## Problem
`CleanReviewView` stacks giant cards per QuickWins hit with Reveal/Add on every row — passive and path-centric.

## Model
`ReviewableTarget` — cleanup unit (often an **app**, not a raw path):
- category: caches | buildArtifacts | packageCaches | other
- displayName, cacheType, bytes, paths[], safety, consequence, symbol
- Built once after scan into `ScanModel.cachedReviewables`

## Caches grouping
1. Find `Library/Caches` directories in the tree (swallow descendants as one hit historically).
2. Walk **immediate children** of each Caches folder → map folder name → app label via known bundle-id prefixes.
3. Add Xcode DerivedData / DeviceSupport as Xcode-related cache targets.
4. Package caches (.npm, .cargo/registry, .gradle/caches, …) as packageCaches category.

## UI
- `SafeToReviewView` for `.cleanSafe` — summary + category chips + recommended checklist
- `CachesReviewView` for `.cleanCaches` — reference layout: summary bar, pills, app table, inspector
- Downloads / Large Media keep improved list (out of scope for deep redesign this pass)
