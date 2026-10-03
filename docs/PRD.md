# PRD — DiskMap

## Goal

Match DiskBuddy feature-for-feature, then use open source's structural
advantages (no license friction, extensible, auditable, free) to exceed it
where that's realistic for a community project to sustain.

## Feature parity target

| Feature | DiskBuddy | DiskMap target | Status |
|---|---|---|---|
| Scan speed | ~10s for 118GB / ~2M files | same order of magnitude | 7.3 s for 1.79M items on a release home scan (2026-09-14). Was 373 s. |
| Treemap view | ✅ | ✅ | verified (TASK-001); drill-down (TASK-003); size toggle (TASK-004) |
| Sunburst view | ✅ | ✅ | one extra ring, Other under 0.5% (TASK-008) |
| Flame graph view | ✅ | ✅ | two rows, Other under 0.5% (TASK-009) |
| Bubbles view | ✅ | ✅ | circle pack, Other under 0.5% (TASK-010) |
| Mind map view | ✅ | ✅ | children on a circle, Other under 0.5% (TASK-011) |
| Top Sizes view | ✅ | ✅ | ranked list, capped at 500 (TASK-012) |
| Age Map view | ✅ | ✅ | heatmap + Big & Untouched (TASK-013) |
| Folders (browsable) view | ✅ | ✅ | drill the existing tree (TASK-014) |
| Duplicate detection (content-based) | ✅ | ✅ | wired (TASK-006); UI (TASK-007) |
| APFS clone detection | ✅ | ✅ | verified (TASK-005); full extent map skips hash (TASK-006) |
| App uninstall + leftovers | ✅ | ✅ | Apps page stages through CleanupQueue (TASK-015) |
| Staged cleanup queue (never auto-delete) | ✅ | ✅ | queue UI confirms to Trash only (TASK-017) |
| Quick Look integration | ✅ | ✅ | from the cleanup queue (TASK-017) |
| Snapshots / compare over time | ✅ | ✅ | versioned binary file, path-matched diff (TASK-018, TASK-019) |
| Quick Wins (node_modules, caches, DerivedData, iOS Simulators) | ✅ | ✅ | categorized JSON patterns on the existing tree (TASK-016; Developer page 2026-09-19) |
| Find-as-you-type search | partial | ✅ | name-table index, ms-scale queries on 1M+ trees (2026-09-19) |
| External/network volume scanning | ✅ | ✅ | should fall out of ScanEngine already, needs testing |
| Offline, no telemetry | ✅ | ✅ | design principle from day one |

## Where an open-source version can realistically do better

These aren't required for parity, but they're differentiators a closed,
paid, single-developer app structurally can't match:

- **No activation friction.** DiskBuddy is one-Mac-at-a-time with a license
  key. DiskMap just runs — no account, no key, no "deactivate this Mac."
- **Auditable.** Anyone can read the source and confirm the "nothing leaves
  your Mac" claim instead of trusting a closed binary's word for it.
- **Extensible regenerable-directory list.** Instead of a fixed "Quick
  Wins" set baked into the app, ship it as an editable/community-maintained
  JSON pattern list (`node_modules`, `.venv`, `target`, `.next`, Xcode
  DerivedData, etc.) that users and contributors can extend without
  needing a new app release.
- **CLI companion.** `DiskMapCore` has zero UI dependencies specifically so
  a `diskmap scan --json ~/` command-line tool is a thin wrapper away —
  useful for scripting, CI disk-usage checks, or headless servers, which a
  GUI-only competitor can't offer at all.
- **Pluggable visualizations.** If the "N views of one scan" idea is
  worth having, an open project can let contributors add a ninth or tenth
  view (e.g. a git-aware view that separately totals tracked vs
  untracked/build output) without waiting on one developer's roadmap.

## Non-goals (at least for v1)

- Windows/Linux support. Native AppKit/SwiftUI integration (Quick Look,
  Finder extensions, APFS-specific APIs) is the whole point of matching
  DiskBuddy's polish — a cross-platform rewrite would trade that away.
- Mac App Store distribution for v1. Sandbox restrictions fight a
  full-disk scanning tool; ship notarized-outside-the-Store first, the way
  DiskBuddy does, and revisit later if there's demand.
