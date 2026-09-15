# Old Downloads redesign architecture

Reference: `docs/reference/DiskMap-OldDownloads.png`

## Role

Old Downloads answers: **Which files in Downloads are large or older, why DiskMap surfaces them, and what you can review — without treating old as deletable.**

Not Biggest Files filtered to Downloads. Not Forgotten Files (whole Mac). Download-scoped, age + type + reviewability.

## Distinction

- **Old ≠ unused** — use last **modified** language only
- **Large ≠ disposable** — personal videos are Review first
- Installers/disk images can be Likely disposable when old enough
- Cleanup queue only — no Delete on this page (Move to Trash stays in Cleanup)

## Target IA

```
Sidebar | Header + summary cards + insight/distribution + filters + dense table | Inspector
```

Multi-select → Add to Cleanup Review. Checkbox ≠ row selection.

## Data

- Walk scan tree for files under paths containing `Downloads`
- Age from `modifiedDay` vs `AgeMap.today()`
- `FileKind` + `SafetyClassifier` for reasons/status
- Cache on ScanModel after scan
