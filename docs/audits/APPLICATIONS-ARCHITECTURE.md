# Applications redesign architecture

Reference: `docs/reference/DiskMap-Applications.png`

## Role

Applications answers: **What is installed, how much space each app uses (bundle + related), how recently it was used, where it came from, and what is reasonable to review?**

Not Finder’s /Applications listing. Application storage intelligence.

## Current problem

`AppsView` is a plain name list + raw leftover paths. No icons, sizes, filters, status, or explanations.

## Target IA

```
DiskMap sidebar | Header + summary + filter chips + search/sort + dense app table | Inspector
```

- Real macOS icons (`NSWorkspace`)
- Summary: count, total size, potentially reviewable
- Filters: All / Large / Not recently used / System / App Store / Other
- Table: checkbox · icon · name · size · last used · source · status
- Inspector: Open/Reveal, Overview/Contents/Insights, size breakdown, related storage, safety, Cleanup only
- Checkbox ≠ row selection; multi-select → bulk Add to Cleanup

## Data

- Enumerate via `AppLeftoverFinder.applicationBundles` (preserve)
- Enrich: allocated bundle size, leftovers (`findLeftovers`), App Store receipt, system path heuristics, last-used when available
- Progressive sizing (async) — do not block first paint
- Status: System / Keep / Review first — never “large = removable”
- No second disk scanner; leftovers remain heuristic and staged for review

## Wire

`.applications` → redesigned `AppsView` with `onOpenCleanup`
Links: File Browser / Visualize / Developer Storage when useful
