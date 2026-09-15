# Large Media redesign architecture

Reference: `docs/reference/DiskMap-LargeMedia.png`

## Role

Large Media answers: **How much storage is media using, what kind, where is it, and what should I review first?**

Not Biggest Files filtered by extension. Media-storage intelligence + review workspace.

## Distinction

- **Biggest Files** = largest individual files on the Mac
- **Large Media** = videos / images / audio / media projects only
- `.dmg` and other non-media never appear
- Personal media age ≠ disposable — default **Review first**
- Cleanup queue primary path; Move to Trash only from inspector

## Taxonomy (`MediaKind`)

Video · Images · Audio · Media Projects · Other (media-adjacent only)

Classification uses extension sets + project package names. Explicit non-media denylist.

## Target IA (reference)

```
Header + 4 summary cards
Type / Location / Age breakdowns (click → filter)
Biggest media opportunities (horizontal cards)
Search + Type/Size/Age/Location + Sort
Dense multi-select table
Footer selection / totals
Inspector (preview · metadata · why · actions)
```

## Data

- Walk existing `FileTree` + `selectedTotals` (canonical / allocated)
- Exclude `/System`, Preboot, top-level `/Library`
- Cache on ScanModel after scan (`cachedLargeMedia`)
