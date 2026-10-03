# File Browser redesign architecture

Reference: `docs/reference/DiskMapFileBrowser.png`

## Role

File Browser answers: **“I want to explore my filesystem myself.”**

It is a **storage-aware Finder**, not another Find/Clean dashboard and not Visualize.

| Page | Question |
|------|----------|
| Biggest Files | What is taking the most space? |
| Biggest Folders | Which folders consume space? |
| Forgotten | What have I forgotten? |
| Safe to Review | What can I clean? |
| **File Browser** | **What’s inside, and how big is it?** |
| Visualize | Spatial / chart exploration |

## Current (before)

`AppShell` mapped `.fileBrowser` → `ExploreShellView` with `exploreMode = .folders`.

That stacked:

- DiskMap sidebar
- Explore secondary sidebar (Recent / Storage / Current View / Quick Wins / File Types)
- Folders canvas
- Permanent inspector
- Bottom `LargestItemsStrip` (redundant with the list)
- Viz mode toolbar

Too much chrome; filesystem lost horizontal space.

## Target IA

```
DiskMap sidebar | Toolbar + breadcrumb + folder header + dense list | Contextual inspector
```

- **No** Explore secondary sidebar on this page
- **No** bottom largest-items strip
- **No** permanent file-types / quick-wins panels
- List is the hero; inspector explains selection

## Navigation

- Own history stack (back / forward); does not re-scan
- Operates on existing `FileTree` + `selectedTotals`
- Breadcrumbs from `FileTree.ancestorIDs`
- Single click = select; double click folder = drill; file = Reveal / open
- Deep link: honor `model.currentNode` / `selectedNode` from other pages

## Data

- Same canonical totals as Overview / Find / Clean (`model.selectedTotals`)
- Folder composition via `FileTypeCatalog.totals(under:)` / `FolderInsight`
- Sort preference persists across folder changes (default: size desc)
- LazyVStack list (virtualized enough for typical folders; huge dirs still from scan index)

## Inspector

- Folder: size, % of used, counts, composition (“What’s inside?”), insight, actions (Finder, Visualize, Biggest Folders, Cleanup if eligible, Copy Path)
- File: size, %, location, modified, why large, actions (Finder, Biggest Files, Cleanup if eligible, Copy Path)
- Protected / System: no cleanup staging
- Technical details behind progressive disclosure

## Wire

- `.fileBrowser` → new `FileBrowserView`
- `.visualize` → existing `ExploreShellView` (unchanged)
- `FoldersView` remains for ExploreShell’s Folders viz mode only
