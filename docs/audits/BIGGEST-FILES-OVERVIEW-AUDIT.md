# Audit: Biggest Files + Overview accounting (2026-09-14)

Branch base: `feature/product-redesign` @ `1bb6867`. Work branch: `feat/redesign-biggest-files`.

## Storage model today

| Piece | Behavior |
|-------|----------|
| Walk | `BulkScan` via `getattrlistbulk` (not `FileManager.enumerator`) |
| Tree | `FileTree` — packed names, parent/firstChild/nextSibling, `logicalSize` + `allocatedSize`, `isDirectory`, `flags` (iCloud dataless) |
| Identity | **Path-only.** No device ID / inode / volume UUID on nodes |
| Symlinks | Skipped (`include: !isLink`); not followed |
| Hard links | Not identified; each directory entry is a separate node if encountered twice |
| Snapshots | Not specially modeled |
| Size metric | Default UI basis `.allocated` (size-on-disk); logical available for toggle |
| Rollup | `rollUpBoth()` — directory total = sum of children (+ own for dirs is 0) |

## Biggest Files — why folders appear

**Root cause (confirmed):** `AppShellView` routes `.biggestFiles` → `TopSizesView` → `TopSizes.ranked(totals:)`.

`TopSizes.ranked` sorts **all node ids** `1..<count` by rolled-up `totals[id]`. Directories carry **subtree** sizes, so `/System`, `/Users`, etc. dominate.

`AnalysisSnapshot.topFileHits` already filters `!isDirectory` — Overview preview can be correct while Find → Biggest Files is wrong.

Parent/child “double listing” is the same bug: A, B, C all appear as independent ranked rows.

## APFS / firmlink duplication

Scanning `/` descends both the firmlink (`/Users`) and the Data-volume path (`/System/Volumes/Data/Users`) if both appear as directories. No firmlink skip exists today → **same bytes can enter the tree twice**, inflating rollups and “Other”.

Display still shows raw `URL.path` (often `/System/Volumes/Data/...`).

## Overview — why Other can exceed Used

1. Header uses `VolumeStats.usedBytes` (true volume capacity accounting).
2. Category bar segments use category byte sums from `categorize()` (sums of **immediate children** of scan root, with Library/Caches peel).
3. Denominator for the bar is `vol.usedBytes`. If firmlink double-counting (or scanning across mounts) makes category sums ≫ used, fractions exceed 1.0 → “Other 638 GB / 100%” vs “363 GB used”.

Categories are also not a true exclusive partition of the volume when the scan root is `/` (System, Data, firmlinks mixed into “other”).

## Size meaning (product copy)

Prefer **allocated** (size on disk) for rankings; call out sparse VM disks (e.g. Docker.raw) in inspector — logical vs allocated can differ.

## Fix plan (this branch)

1. `TopSizes.rankedFiles(tree:totals:)` — files only; keep `ranked` for Explore Top Sizes mode or rename.
2. Firmlink / Data-volume descend skip when canonical twin already in tree (path rules + optional `/usr/share/firmlinks`).
3. `CanonicalPath` display helpers (`~/…`, prefer `/Users` over Data twin).
4. Exclusive Overview categories + bar denominator = sum(categories) or scanned root, never imply Other > used.
5. New Biggest Files page UI + inspector (ref: `DiskMap-BiggestFiles.png`).
6. Overview quiet health + worth-looking-at + honest reclaim copy.
7. Regression tests.

## Non-goals this branch

Duplicates / Forgotten / Visualize / Developer redesigns.
