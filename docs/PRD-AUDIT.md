# PRD feature-completeness audit (TASK-026)

Date: 2026-09-14. Machine: AYUSHs-MacBook-Air.local. Branch: `perf/scan-and-runtime`.
Method: `swift test` (42/42 green) + code-path inspection + prior `docs/PERF.md` benches.
**No fixes in this task** — punch list only.

## Parity table

| Feature | Status | Evidence | Gap |
|---|---|---|---|
| Scan speed (~10s / ~2M) | **Working** | Release home benches in `docs/PERF.md`: confirm-defaults-v2 median **5.94 s** (~1.8M items); cold post-reboot median 10.5 s / min 5.9 s; warm bands ~6–11 s. | Session noise remains; not a feature gap. |
| Treemap view | **Working** | `SquarifiedTreemapTests` green; `ContentView` Map tab → `TreemapContainerView`; drill-down + Logical/On Disk picker present. | None for parity. |
| Sunburst view | **Working** | `ChartLayoutTests` + `LayoutChartView` sunburst case; sidebar tab wired. | Manual UI click not re-run this session; layout algorithm + wiring confirmed. |
| Flame graph view | **Working** | Same chart pipeline; Flame tab wired in `ContentView`. | Same as sunburst. |
| Bubbles view | **Working** | `CirclePackTests` green; Bubbles tab wired. | Same. |
| Mind map view | **Working** | Mind Map tab → `LayoutChartView` mind-map mode. | Same. |
| Top Sizes view | **Working** | `BrowseQueryTests.topSizesSkipsRootAndCaps`; `TopSizesView` wired. | None. |
| Age Map view | **Working** | `BrowseQueryTests.ageBucketsAndUntouchedUseAFixedToday`; `AgeMapView` wired. | None. |
| Folders (browsable) | **Working** | `FoldersView` drills `currentNode` on existing tree. | None. |
| Duplicate detection | **Working** | `DuplicateFinderTests` (incl. clone skip + independent copy hash) green; Duplicates tab wired. | Memory-at-scale still TASK-028. |
| APFS clone detection | **Working** | `CloneDetectorTests` green; `F_LOG2PHYS_EXT` full extent map; non-APFS returns nil → `areLikelyClones` false (code). | Non-APFS runtime confirm is TASK-027. |
| App uninstall + leftovers | **Working (core)** | `AppLeftoverFinder` + `AppsView` stages through `CleanupQueue`; `applicationBundlesAreAppFoldersOnly` test. | No automated leftover-path integration test against a real `/Applications` uninstall flow. |
| Staged cleanup queue | **Working** | `CleanupQueue` uses `trashItem` only; UI confirmation dialog; reclaim tests for clones. | No end-to-end Trash move in CI (destructive). |
| Quick Look | **Implemented, lightly verified** | `QuickLookPresenter` + button on cleanup queue rows (`QLPreviewPanel`). | No automated QL test; needs one manual click in the app. |
| Snapshots / compare | **Working (diff)** | `SnapshotTests.roundTripAndDiffReportsOneSidedFolders`; Snapshots page save + path-matched diff. | **Reopening a snapshot into the treemap is explicitly not implemented** (TASK-019 note). |
| Quick Wins | **Working** | `QuickWinsTests` + bundled `quick-wins-patterns.json`; Quick Wins tab. | Patterns load from `Bundle.module` only — not yet a user-editable file without rebuild (see differentiators). |
| External/network volume scanning | **ExFAT confirmed; network N/A** | RAM ExFAT `/Volumes/DISKMAP` scan 302 items; CloneDetector clean fail (TASK-027, `docs/EDGE-ROBUSTNESS.md`). No SMB/AFP/NFS mounts. | Network share still untested until one is mounted. |
| Offline, no telemetry | **Working** | Grep of Sources: no `URLSession` / analytics / telemetry sinks in app/core. | None. |

## “Do better” differentiators

| Differentiator | Status | Evidence | Gap / decision |
|---|---|---|---|
| No activation friction | **Met** | No license/activation code paths; SPM app launches directly. | Formal Gatekeeper path still needs ad-hoc/notarized build (TASK-029 / deferred 020–021). |
| Auditable | **Met** | Public GitHub `Ayushjo/Diskmap`; core logic in readable Swift. | Keep shipping source with releases. |
| Extensible regenerable-directory list | **Partial** | JSON patterns shipped and tested; comment says “grow without app release.” | **Deferred**: runtime load from Application Support / user override not implemented — still Bundle-only. Reason: v1 ships bundled list; community edit path is a small follow-up once ad-hoc builds exist. |
| CLI companion (`diskmap scan --json`) | **Partial** | `DiskMapScanBench --json` exists as measurement CLI; `DiskMapCore` has no UI deps. | **Deferred**: product `diskmap scan --json` binary/name not shipped. Reason: bench covers measurement; product CLI is a thin rename/wrap after TASK-029 packaging. |
| Pluggable visualizations | **Deferred** | Fixed enum of chart modes in app; no plugin API. | **Deferred**: contributor adds a view via PR, not a runtime plugin. Reason: SwiftUI embedding + API surface is post-v1; open contribution via source already enables a 9th view. |

## Punch list (for “better than DiskBuddy”)

1. Confirm external/exFAT (+ network if available) scan + CloneDetector fallback — **TASK-027**.
2. DuplicateFinder RSS at scale — **TASK-028**.
3. Ad-hoc `DiskMap.app` package — **TASK-029**.
4. Optional later: snapshot→treemap reopen; user-editable Quick Wins JSON; product CLI name; Quick Look manual smoke; full leftover uninstall E2E.
5. Still deferred by Milestone 6 resequence: paid Developer ID, notarization, Sparkle (TASK-020/021/022).

