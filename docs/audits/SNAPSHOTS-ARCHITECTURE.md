# Snapshots redesign architecture

Reference: `docs/reference/DiskMap-Snapshots.png`

## Role

Snapshots answers: **How did my storage change between two points in time?**

Analytical DiskMap checkpoints — **not** Time Machine, file backups, or APFS filesystem snapshots.

## Current problem

`SnapshotDiffView` is Save + Before/After pickers + flat path list. No history, metadata, category attribution, or inspector.

## Target IA

```
DiskMap sidebar | History list + Compare workspace + change tables | Inspector
```

- Save Snapshot (name + optional note)
- Storage history rows (date, used/free, Current badge for live scan)
- Before/After selectors + Compare
- Delta summary (used / free)
- Where did it change? (category bars from AnalysisSnapshot categories)
- Largest changes table (Added / Removed / Grew / Shrunk)
- Inspector for selected change or snapshot
- Links to Visualize / File Browser / Developer Storage / Applications
- Delete removes DiskMap analysis only — never user files

## Data

- Preserve `DiskSnapshot` binary codec (v1/v2) + `SnapshotStore`
- Sidecar `.meta.json` for name, note, volume used/free/total, file/folder counts, favorite
- Compare via `SnapshotDiff` using **CanonicalPath.displayPath** keys (no firmlink double-count)
- Category deltas via `AnalysisSnapshot.build` on each side
- Threshold filter for noise; off-main-thread compare for large trees

## Wire

`.snapshots` → `SnapshotsView(model:)` replacing bare `SnapshotDiffView`
