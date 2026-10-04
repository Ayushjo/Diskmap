# Visualize redesign architecture

Reference: `docs/reference/DiskMapVisualize.png`

## Role

Visualize answers: **Where is storage going, spatially?**

Not File Browser (navigate listing). Not Find (ranked lists). A storage exploration workspace.

## Current problem

`ExploreShellView` embeds visualization inside a **file-browser chrome**:
DiskMap sidebar + Explore secondary sidebar (Recent/Disk/Quick Wins/File Types) + canvas + inspector + card strip.

Too many columns; viz loses space; feels like a chart bolted onto a browser.

## Target IA

```
DiskMap sidebar | Header + crumbs + mode toolbar + summary + viz + largest table | Inspector
```

- No Explore secondary sidebar
- Treemap default
- Mode switch preserves location/selection
- Compact largest-items **table** (not horizontal cards)
- Contextual inspector (what / size / where / why / actions)
- Same `selectedTotals` + `CanonicalPath` firmlink skip as rest of app

## Data correctness

Reuse existing:
- `BulkScan` + `CanonicalPath.shouldSkipDescend` (no APFS double-walk)
- `selectedTotals` (allocated/logical basis)
- `FileTypeCatalog` / `FolderInsight` for composition
- Do **not** invent a parallel size model

UI filters zero-size / empty firmlink twin shells from root children when presenting viz.

## Modes (Visualize picker)

Treemap · Sunburst · Flame · Bubbles · Mind Map · Age Map  
(Folders / Top Sizes stay out of this picker — File Browser / Find cover them.)

## Wire

`.visualize` → `VisualizeView`  
`ExploreShellView` remains for any legacy path but is no longer the Visualize destination.
`ExploreCanvas` / treemap / layout charts reused inside VisualizeView.
