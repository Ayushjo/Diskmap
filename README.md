# DiskMap — an open-source starting point

## Start here

- **Working in this repo with Cursor or another AI agent?** Read
  `AGENTS.md` first — it's the always-relevant context, plus `.cursor/rules/`
  scopes extra rules to the riskiest files automatically.
- **Setting the project up on your Mac?** `SETUP.md` — what needs to be
  done by hand vs. what Cursor can do.
- **Want the actual work breakdown?** `TASKS.md` — ordered tickets, each
  with acceptance criteria and a ready-to-paste Cursor prompt.
- **Want the feature target / what "done" means?** `docs/PRD.md`.
- **Want the design rationale / why things are built this way?**
  `docs/ARCHITECTURE.md`.

---


A scaffold for building a fully open-source Mac disk-space analyzer aimed
at matching or beating DiskBuddy: eight visualizations of one scan,
content-based duplicate detection with APFS clone awareness, an app
uninstaller that catches Library leftovers, and a staged cleanup queue
that never deletes anything without review.

## Status: untested scaffold, not a working app yet

**Important:** this was written in a Linux sandbox with no macOS or
Xcode available, so none of this has been compiled or run. It's real,
intentional code — not pseudocode — but treat every file as "first draft,
needs a build-and-fix pass on your Mac," especially:

- `SquarifiedTreemap.swift` — layout verified against the paper's 6×4
  example (TASK-001). `swift test` checks full-area coverage without
  gaps/overlaps.
- `CloneDetector.swift` — verified in TASK-005 against the SDK's packed
  `log2phys` (`#pragma pack(4)`, 20 bytes) and a real `cp -c` pair.
  Extent maps use `F_LOG2PHYS_EXT`. A hand-rolled Swift struct of the
  same fields is the wrong size.
- Everything else (`FileTree`, `ScanEngine`, `DuplicateFinder`,
  `AppLeftoverFinder`, `CleanupQueue`) is more conventional Foundation
  code and more likely to just work, but hasn't been exercised against a
  real multi-million-file scan.

## Get it running

```bash
cd DiskMap
swift test    # run this first — checks the treemap math
swift run DiskMapApp   # launches a window; SwiftUI App executables work fine via SPM on macOS 13+
```

Once it's stable, convert to a proper `.xcodeproj` (File → New → Project
from existing package works, or just `open Package.swift` in Xcode) —
you'll want that anyway for code signing, notarization, and an app icon
before distributing to anyone else.

## What's here vs. what's next

| Module | Covers | DiskBuddy feature it maps to |
|---|---|---|
| `FileTree.swift` | Memory-efficient scanned-tree storage | The "3.2 GB → 18 MB" memory fix |
| `ScanEngine.swift` | Async, incremental directory walk | The 10-second scan |
| `SquarifiedTreemap.swift` | One treemap layout, one view | 1 of 8 visualizations |
| `DuplicateFinder.swift` | Size → partial hash → full hash | Duplicate scan |
| `CloneDetector.swift` | APFS clone detection via extents | "Detects APFS clones" |
| `AppLeftoverFinder.swift` | Library leftover matching | App uninstall |
| `CleanupQueue.swift` | Stage-then-Trash, never auto-delete | Staged cleanup queue |

Not started yet — sunburst, flame, bubbles, mind map, top sizes, age
map, folders view; Quick Look integration; snapshots/diffing; Finder
extension for right-click uninstall; Quick Wins (node_modules, caches,
DerivedData totals); notarization and an update mechanism. All of these
are additive on top of the same `FileTree`/`totals` data this scaffold
already produces — the treemap, sunburst, flame graph, and bubbles views
are four different layout functions over the *same* `children(of:totals:)`
call `TreemapContainerView` already makes.

## Research notes worth keeping

**Why struct-of-arrays instead of a class per file.** A `class FileNode`
with a handful of stored properties costs roughly 48+ bytes of
object/ARC/isa overhead before a single field is stored, and every
`String` property is a separate heap allocation. At a few million files
that's easily gigabytes of pure overhead — almost certainly the exact
category of bug DiskBuddy's 1.1.3 changelog describes fixing. The
`FileTree` struct here stores every field in its own packed array,
indexed by `Int32`, with folder/file names interned once instead of
re-allocated per occurrence (`node_modules`, `Library`, `.git` repeat
constantly across a real filesystem).

**APFS clone detection.** Apple doesn't expose a high-level "is this a
clone of that" API. The real technique, confirmed by an Apple Developer
Forums thread and a small community tool built specifically for this
([apfs-clone-checker](https://github.com/dyorgio/apfs-clone-checker)),
is comparing physical block offsets via `fcntl`'s `F_LOG2PHYS` — hard
links share an inode and can be detected via `getattrlist`/`statfs`
link-count fields, but clones use *different* inodes while sharing
underlying extents, so you have to go one level lower and compare
physical storage directly. Once verified on-device, this becomes a
duplicate-finder optimization too: two files at the same physical offset
are guaranteed byte-identical, so the dedup engine can skip hashing them.

**App leftover matching is unavoidably heuristic.** There's no Apple API
enumerating everything an app touched. Every open-source uninstaller in
this space (AppCleaner, Pearcleaner) does the same thing this scaffold
does: search known Library locations for items whose name contains the
app's bundle identifier, falling back to a fuzzy name match when no
bundle ID is available. This is why `CleanupQueue` stages everything for
review instead of ever deleting automatically — the matching will
occasionally be wrong, and staging is what makes that safe rather than
scary.

**Distribution model.** DiskBuddy ships notarized-but-not-sandboxed,
outside the Mac App Store, which is what lets it request broad
filesystem access (Full Disk Access) instead of fighting the App
Sandbox's per-file-access-grant model. That's almost certainly the right
call for this project too — a disk analyzer that has to ask permission
for every folder it wants to look inside isn't really doing its job.
Budget time for an Apple Developer account, notarization, and a
Sparkle-style update mechanism before this is something you'd hand to
anyone else.

## Existing open-source projects worth borrowing from rather than
## reinventing

- **[Czkawka](https://github.com/qarmin/czkawka)** (MIT, Rust) — the
  best open-source duplicate/similar-image engine that exists right now.
  Its `czkawka_core` crate is usable standalone; calling it via a small
  Rust↔Swift bridge (or just shelling out to the CLI initially) could
  replace `DuplicateFinder.swift` entirely and skip re-deriving a hashing
  pipeline that's already fast and already well-tested.
- **[GrandPerspective](https://grandperspectiv.sourceforge.net/)** (GPL,
  Objective-C) — its actual treemap rendering code is public and has 20
  years of edge cases worked out. Worth reading even if you don't reuse
  code directly, given the GPL license would require this project to be
  GPL too if you link against it.

## Suggested license

**MIT**, matching Czkawka and the AppCleaner fork rather than
Pearcleaner's fair-code restriction or GrandPerspective's GPL — maximizes
who can use and contribute to it, and keeps the door open to eventually
depending on Czkawka's MIT-licensed core without a license conflict.

## Suggested milestone order

1. Get `FileTree` + `ScanEngine` + one treemap view scanning a real
   folder and rendering correctly — validates the memory/perf story
   before anything else.
2. `DuplicateFinder` + `CloneDetector`, verified against a real APFS
   clone pair.
3. Remaining visualizations (sunburst, flame, bubbles, mind map, top
   sizes, age map, folders) — same underlying data, different layout math.
4. `AppLeftoverFinder` + Finder-drag-to-scan + `CleanupQueue` UI.
5. Snapshots (serialize `FileTree` + totals to disk, diff two scans).
6. Notarization, signing, update mechanism, icon/polish.
