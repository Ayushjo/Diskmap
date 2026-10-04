# Forgotten Files — architecture (2026-09-14)

Branch: `feat/redesign-forgotten-files` (from `feat/redesign-biggest-folders`).
UI reference: `docs/reference/DiskMap-ForgottenFiles.png`.

## Bug in current UI

`AgeMapView` (Find → Forgotten) showed:
- Header **forgottenBytes** = sum of `AgeMap.untouched` (files >1y, capped at 200) via `AnalysisSnapshot`
- Heatmap **bucketSizes** = **all scanned files by age** (including <30d …)

So the chart could show hundreds of GB while the header showed ~7 GB. Datasets were conflated.

## Product definition

Forgotten ≠ old.

**Forgotten candidate** = large-ish file, modified >1 year ago, in a personal/reviewable context, not system/app-managed — ranked by review value (size × age × location × type − risk).

Confidence:
- `likelyForgotten` — Downloads/Movies/Desktop/Documents + media/archive/dmg/iso, safety ≠ protected
- `worthReviewing` — other user paths, safety `.safe`/`.review`, size meaningful
- `oldImportant` — app bundles, Developer, System, managed (Docker.raw, etc.) — excluded from default list

## Data separation

| Dataset | Meaning |
|---------|---------|
| `ForgottenFiles.candidates` | Files matching forgotten criteria + confidence |
| `ForgottenFiles.ageDistribution` | Bytes of **candidates only**, buckets ≥1y |
| Explore `AgeMap.bucketSizes` | All files by age (unchanged for Visualize Age Map) |

Header totals = sum of shown confidences (likely + worth by default).

## UI

New `ForgottenFilesView` for Find (Explore Age Map keeps `AgeMapView`).
Matches Biggest Files chrome: cream list + ~320pt inspector, checkboxes, Review selected → Cleanup sheet.
