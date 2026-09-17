# AGENTS.md

Context for any AI coding agent (Cursor, Claude Code, etc.) working in this
repo. Read this before making changes. Read `docs/PRD.md` and
`docs/ARCHITECTURE.md` before starting a new feature area.

## What this is

DiskMap: an open-source, native macOS disk-space analyzer. The target is
feature parity with — and eventually better than — DiskBuddy, a closed-source
$9–49 one-time-purchase app. Full feature target: `docs/PRD.md`. Design
rationale and research notes: `docs/ARCHITECTURE.md`. Actual work breakdown,
in order, with acceptance criteria: `TASKS.md`.

## Non-negotiable rules

1. **Never delete files directly.** All removal goes through
   `CleanupQueue.commit()`, which uses `FileManager.trashItem` (moves to
   Trash) — never `unlink` or `FileManager.removeItem`. If you're building a
   new cleanup feature, route it through `CleanupQueue`; don't add a second
   deletion path.
2. **Nothing calls the network.** Grep for outbound `URLSession`/networking
   before merging anything. Fully offline is a stated product promise and a
   differentiator over closed competitors — don't regress it by accident
   (e.g. adding a crash reporter or analytics SDK).
3. **The excluded-paths list in `CleanupQueue.swift` is the last line of
   defense** against staging something like `/System`. Any change to it
   needs to be called out explicitly in your summary of the change, not
   silently modified as part of a larger diff.
4. `CloneDetector.swift` is verified (TASK-005) against the SDK's packed
   `log2phys` and a real `cp -c` pair. `SquarifiedTreemap.swift` is
   verified (TASK-001). Don't build on a file that still says `UNVERIFIED`
   in its header until that warning is removed the same way.

## Build & test

```bash
swift build
swift test
swift run DiskMapApp
```

Run `swift test` after every change before calling a task done. If there's
no test covering what you just changed, write one — see
`Tests/DiskMapCoreTests` for the pattern (Swift Testing, not XCTest —
Command Line Tools don't ship XCTest, so `import XCTest` fails `swift test`
on a machine without full Xcode; no mocking framework, prefer real small
filesystem fixtures over mocks where practical).

## Where things live

- `Sources/DiskMapCore/` — headless logic: scanning, dedup, cleanup, clone
  detection. **No SwiftUI/AppKit imports here** — this code needs to stay
  testable without a UI and reusable from a future CLI companion tool.
- `Sources/DiskMapApp/` — SwiftUI views and AppKit glue (NSOpenPanel, Quick
  Look panel, etc).
- `docs/PRD.md` — feature targets and what "done" means per feature.
- `docs/ARCHITECTURE.md` — why things are built the way they are, including
  a running decision log.
- `TASKS.md` — the work breakdown. Work top to bottom. Each ticket has its
  own acceptance criteria and a ready-to-paste prompt.

## Verify, don't assume, on macOS-specific APIs

Parts of this codebase were originally written without a macOS toolchain
available and are flagged `UNVERIFIED` in comments. When you touch one:

- Check the real header or Apple's official docs rather than trusting an
  existing comment's claimed constant value or struct layout.
- Once confirmed against a real build and a real test, update or remove the
  `UNVERIFIED` warning — don't leave stale warnings once something's fixed,
  and don't remove a warning without actually having verified it.

## Style

- Swift API Design Guidelines defaults.
- No force-unwraps in `DiskMapCore` outside of tests. This code walks
  arbitrary, sometimes-hostile filesystem state — broken symlinks,
  permission-denied files, huge sparse files, mid-scan file deletion — and
  should degrade to `nil`/skip rather than crash.
- Prefer structs + free functions over classes in `DiskMapCore` unless you
  have a specific reference-semantics need. This isn't just a style
  preference here — see the memory-layout rationale in
  `docs/ARCHITECTURE.md` for why per-node object overhead is the specific
  bug this project exists partly to avoid repeating.

## Windows port (`windows/`)

A sibling C#/.NET 10 port lives under `windows/` (`src/DiskMap.Core`,
`app/DiskMap.App` WPF, `tests/DiskMap.Core.Tests` xUnit). Same rules apply:
no direct deletion (Recycle Bin via `SHFileOperation(FOF_ALLOWUNDO)` only,
in `CleanupQueue`), no networking, `windows/src/DiskMap.Core/CleanupQueue.cs`
holds the Windows excluded-paths list — changes to it get called out.
Files marked `UNVERIFIED` follow the same verify-then-unflag rule.
Build/test: `dotnet build windows\DiskMap.Win.slnx`, `dotnet test windows\DiskMap.Win.slnx`.
