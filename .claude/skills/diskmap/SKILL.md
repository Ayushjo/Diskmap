---
name: diskmap
description: >
  Working on DiskMap — the open-source native macOS (SwiftUI + SwiftPM) disk-space
  analyzer in this repo. Load whenever a task touches scanning, treemap/visualizations,
  duplicate/clone detection, app-leftover cleanup, the CleanupQueue, snapshots, or any
  DiskMapCore/DiskMapApp Swift file. Carries the non-negotiable safety rules, the
  build/test loop, and where everything lives.
---

# DiskMap

Open-source native macOS disk-space analyzer (SwiftUI + Swift Package Manager),
targeting feature parity with the closed-source app DiskBuddy. Two layers:

- `Sources/DiskMapCore/` — headless, testable logic. **No SwiftUI/AppKit imports here.**
  Scanning (`ScanEngine`, `FileTree`), dedup (`DuplicateFinder`, `CloneDetector`),
  cleanup (`CleanupQueue`, `AppLeftoverFinder`), catalogs and layout math.
- `Sources/DiskMapApp/` — SwiftUI views + AppKit glue (NSOpenPanel, Quick Look).

Full context: `AGENTS.md`. Feature targets: `docs/PRD.md`. Design rationale +
decision log: `docs/ARCHITECTURE.md`. Ordered work breakdown + acceptance criteria:
`TASKS.md` (the source of truth for status — check items off there).

## Non-negotiable rules

1. **Never delete files directly.** All removal routes through `CleanupQueue.commit()`,
   which moves to Trash via `FileManager.trashItem` — never `unlink` or
   `FileManager.removeItem`. Don't add a second deletion path.
2. **No networking, anywhere.** Offline-only is a product promise. Grep for outbound
   `URLSession`/networking before merging; don't add analytics or crash reporters.
3. **Two-step cleanup boundary.** Staging (`CleanupQueue.stage()`) and committing
   (moving to Trash) must stay separate actions. No one-click "scan and clean" — that's
   a deliberate human product decision, not a default. Every new source of staged items
   must go through `stage()`, which enforces the excluded-paths check.
4. **The excluded-paths list in `CleanupQueue.swift` is the last line of defense**
   against staging something like `/System`. Any change to it must be called out
   explicitly in the change summary — never modified silently inside a larger diff.
5. **App-leftover matching is heuristic by design.** Bias toward fewer false positives:
   a missed leftover costs a few KB; a wrongly-flagged real file costs user trust.
6. **New "Quick Wins" / regenerable-dir patterns are data, not code** — extend
   `quick-wins-patterns.json` / `file-type-categories.json`, not hardcoded lists.

## Build & test

```bash
swift build
swift test
swift run DiskMapApp
```

- Run `swift test` after **every** change before calling a task done. If nothing covers
  what you changed, write a test — pattern in `Tests/DiskMapCoreTests`.
- **Swift Testing, not XCTest** (`import XCTest` fails `swift test` without full Xcode).
  Prefer small real filesystem fixtures over mocks.
- No force-unwraps in `DiskMapCore` outside tests — it walks hostile filesystem state
  (broken symlinks, permission-denied, sparse files, mid-scan deletion) and must degrade
  to `nil`/skip rather than crash.

## Low-level files — verify against the real SDK, don't trust comments

`CloneDetector.swift` (APFS clone detection via `fcntl` `F_LOG2PHYS`/`F_LOG2PHYS_EXT`)
and `SquarifiedTreemap.swift` were originally written without a macOS toolchain. Both are
now verified (TASK-005, TASK-001). If you touch them:

- Confirm struct layout / constants against `<sys/fcntl.h>` in the active SDK
  (`xcrun --show-sdk-path`), not against the file's comment.
- Test clone detection against a real `cp -c` pair on APFS; treemap against the paper's
  `[6,6,4,3,2,2,1]` in a 6×4 rect (Bruls/Huizing/van Wijk 2000, Fig 6). Keep the
  "full area, no gaps/overlaps" assertion — don't weaken it to pass.
- Only remove an `UNVERIFIED` header after actually verifying; note what you confirmed.

## Style

Swift API Design Guidelines. Prefer structs + free functions over classes in
`DiskMapCore` — per-node object/ARC overhead is the specific memory bug this project
exists to avoid (see `docs/ARCHITECTURE.md`; `FileTree` is struct-of-arrays indexed by
`Int32` with interned names).
