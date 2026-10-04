# DiskMap — next roadmap: power-user features, UX, and speed

Written 2026-09-25 against `feat/diskmap-product-redesign` @ 8190439.
Companion to `docs/PRD.md` (what parity means) and `docs/PERF.md` (how we
measure). Nothing here is a task yet — promote items into `TASKS.md` with
acceptance criteria before building.

## Where we actually are

Parity with DiskBuddy is effectively done (`docs/PRD-AUDIT.md`): 8
visualizations, content dedup with APFS clone awareness, app-leftover
uninstall, staged Trash-only cleanup, snapshots + diff, Quick Wins,
Developer Storage. Scan is `getattrlistbulk` + 8 workers: **1.8M home
items in 5.9 s median warm** (min 5.88 / max 8.95, `confirm-defaults-v2`).

So the interesting question is no longer "can we match DiskBuddy." It's:
**a disk analyzer is a tool you open twice a year — what makes a developer
open it every week?** Everything below is scored against that.

The honest answer is that the current app tells you *where the bytes are*,
which is the solved half. What it does not yet tell you is **what it costs
you to get them back** — and that is the entire decision a developer
actually makes when they look at a 40 GB `node_modules` pile.

---

# Part A — Feature bets

Ordered by (value to a technical user) ÷ (cost, given the engine we have).
Everything in A1–A4 runs on the *existing* `FileTree` + `totals` from one
walk — no second pass over the disk.

## A1. Make Developer Storage decision-grade, not just descriptive

`DeveloperCatalog.swift` today matches directory **names** (`node_modules`,
`target`, `DerivedData`, …) and labels them reclaimable / review-first /
keep. That is a good skeleton and the wrong unit of analysis. A developer
staring at 40 GB of `node_modules` across 60 folders does not need to be
told it is 40 GB. They need to know *which of those 60 they can nuke
without pain.* Four deterministic signals answer that, and we can read all
four offline:

**1. Project root by manifest, not by parent directory.**
Today `projectFromParent: true` calls the parent of `node_modules` the
project. That is wrong for monorepos, pnpm workspaces, and nested
packages. Detect the root by walking up to the nearest `package.json`,
`Cargo.toml`, `go.mod`, `pyproject.toml`, `Package.swift`, `*.xcodeproj`,
`pubspec.yaml`, `pom.xml`. Correct grouping is the prerequisite for
everything else here.

**2. Rebuild cost, as a first-class column.**
This is the feature. Split reclaimable into:

| Class | Meaning | Examples |
|---|---|---|
| Free | regenerates offline, seconds–minutes | `__pycache__`, `.next`, `dist`, `.mypy_cache` |
| Cheap | regenerates offline, minutes–hours of CPU | `target/`, `DerivedData`, `.gradle` build output |
| Networked | needs a working network + live registry | `node_modules`, `.venv`, `Pods`, `vendor/` |
| Networked, unpinned | as above **and no lockfile present** | any of the above without `package-lock.json` / `yarn.lock` / `Cargo.lock` / `poetry.lock` / `uv.lock` |

That last row is the one nobody ships. "This 3 GB `node_modules` has no
lockfile — reinstalling may not reproduce what you have" is real, checkable,
and exactly the thing that ruins someone's afternoon. Pure filesystem
inspection, no network, fully deterministic.

**3. Git state of the owning repo.**
Read `.git/HEAD`, `.git/refs/`, `.git/config` directly — no `git` subprocess,
no network. Derive: is this a repo, does it have an `origin` remote, are
there refs not present in `refs/remotes/origin/`. Then the app can say
"this project is pushed to origin — the whole folder is recoverable" versus
"unpushed commits on `main`, do not delete this directory." That single
distinction is worth more than another visualization.

**4. Last *source* touch, ignoring build output.**
`FileTree.modifiedDay` already exists per node. Max mtime over the project
excluding the reclaimable subtrees = when the human last worked on it.
Unlocks the headline that makes people open the app:
*"23 projects untouched for 6+ months are holding 41 GB of dependencies."*
`ForgottenFiles.swift` already does age-ranking for files; this is the same
idea at project granularity, which is the unit developers actually think in.

**5. `.gitignore` as a reclaimability oracle.**
Anything git ignores is, by the repo author's own declaration, regenerable
and not tracked. Parsing the repo's ignore rules gives a per-repo
"ignored bytes" number that is more trustworthy than our hardcoded name
list, and it covers ecosystems we have no rule for. No competitor does this.
Start read-only (report ignored bytes per repo); consider staging later.

## A2. Tool-native cleanup recipes — show the command, never run it

Several of the biggest developer directories are actively **wrong** to move
to Trash, and the current app has no way to say so:

- **Docker** — `~/Library/Containers/com.docker.docker/.../Docker.raw` is a
  single sparse disk image. Trashing it destroys every image, volume and
  container at once. The correct action is `docker system prune -a` or
  `docker builder prune`, which reclaims inside the image.
- **iOS Simulators** — `CoreSimulator` folders are tracked in `simctl`'s
  own database. Deleting directories underneath it corrupts that state;
  `xcrun simctl delete unavailable` is the supported path.
- Same shape: `brew cleanup`, `npm cache clean --force`, `pnpm store prune`,
  `uv cache clean`, `cargo cache -a`, `go clean -modcache`.

So: for these targets, replace the "Add to Cleanup" button with the actual
command, a **Copy** button, and a one-line explanation of why we are not
doing it for you. This *respects* non-negotiable rule #1 rather than
straining against it — DiskMap never becomes a second deletion path, and it
stops quietly recommending a destructive action. It also tells the user
something they did not know, which is the whole product thesis.

This alone likely prevents a class of "DiskMap ate my Docker volumes" bug
report, and it is a few hundred lines of catalog data.

## A3. Reconcile the volume: explain the bytes we *cannot* see

`VolumeStats` (statfs) already gives used/free, and `OverviewView` prints
them. But nothing reconciles **volume used** against **bytes we actually
walked**. On a real Mac that gap is enormous and it is the single most
common "where did my disk go" confusion:

- APFS local Time Machine snapshots (often 10–50 GB, invisible to a walk)
- purgeable space
- other volumes, other users, `/System`
- whatever the scan could not read (see A4)

A first-class Overview row — *"You scanned 312 GB of 494 GB used. The other
182 GB is: …"* — converts the app's most confusing moment into its most
trusted one. Deterministic, offline, and the data is nearly all in hand.

## A4. Surface unreadable directories instead of silently zeroing them

**This is a correctness bug, not a feature.** In `BulkScan.swift:87`, when
`open()` fails the directory is recorded with no children and the failure
is discarded:

```swift
guard fd >= 0 else {
    state.noteEmptyDirectory()
    return
}
```

Nothing in `Sources/` counts, stores, or reports that (grep for
`unreadable` / `deniedCount`: zero hits). Without Full Disk Access, a scan
of `~/Library` or `/` reports confidently wrong totals and the user has no
way to know. Fix: count `errno == EACCES/EPERM` separately, carry it on
`ScanEngine.Result`, and show "N folders could not be read — grant Full
Disk Access" with a button that deep-links to the Settings pane. Cheap,
and it protects every number the app displays.

## A5. `diskmap` CLI — the differentiator the PRD names and we never built

`docs/PRD.md` calls this out explicitly and `DiskMapCore` has zero UI
imports *specifically* to make it possible. `DiskMapScanBench` is a
measurement wedge, not a product. Ship:

```
diskmap scan ~/code --json
diskmap dev --reclaimable --older-than 6m
diskmap dup ~/Downloads
diskmap check --fail-over 50GB        # exit 1 for CI / pre-commit
```

Real uses: a CI step that fails when a build image bloats, a pre-commit
hook that catches a committed `node_modules`, scripting on a headless box,
and `diskmap dev --json | jq` for people who will never open a GUI. A GUI-only
competitor structurally cannot offer this. Cost is genuinely low — it is a
thin `ArgumentParser` wrapper over calls the app already makes.

## A6. Query language in ⌘K

`CommandPalette.swift` exists and handles commands + top file/folder hits.
Technical users want to express a filter, not click one:

```
ext:mp4 size>500mb age>1y path:~/Downloads
name:*.log size>100mb
```

Every field is already in `FileTree` (name, size, modifiedDay, createdDay,
isDirectory). This replaces the need for several near-duplicate list screens
(see B3) with one surface power users will actually prefer.

## A7. Honest reclaim math for clones and hard links

`CloneDetector` is verified and the dedup engine uses it, but tree totals
still count a cloned/hard-linked file once per path. A selection of five
clones of one 4 GB file shows as 20 GB and frees 4 GB. At minimum, the
cleanup queue should compute **true bytes reclaimed** for the staged set and
say so before you commit. Shipping a number that is 5× wrong at the exact
moment of the destructive action is the worst place to have it.

## A8. Export

`--json`, NDJSON, CSV, and an `ncdu`-compatible dump. Plus "copy paths of
selection" so someone can build their own `rm` line. Fits the offline
promise, costs almost nothing, and makes the tool composable.

## Deliberately not doing

An AI assistant, a "cleanliness score", gamified badges, one-click
auto-clean, animated bytes flying into a trash can, a background daemon
that nags. These are the things that make a utility feel like adware, and
one-click clean directly violates non-negotiable rule #3.

---

# Part B — UI/UX

## B1. Dark mode (highest-ranked UX item)

`.preferredColorScheme(.light)` is hardcoded in four places
(`AppShellView.swift:73,78,83`, `ExploreShellView.swift:41`,
`CleanupQueueView.swift:115`). The cream `#FAF5EC` / ink `#1C1B17` identity
is genuinely nice, but a Mac utility that ignores the system appearance
reads as "not really native" to exactly the audience we are courting —
and this audience is disproportionately in dark mode all day.

Work: turn `DesignSystem.swift` from literal colors into semantic tokens
(`surface`, `surfaceRaised`, `stroke`, `label`, `mutedLabel`, `accent`),
each with a light and dark value, then delete the five overrides. The
treemap/sunburst palettes need a parallel dark ramp — `ExploreColoring.swift`
is the one place that matters, since a palette tuned on cream will vibrate
on near-black. Do this once, early; retrofitting it after more views land
gets linearly more expensive.

## B2. Progressive first paint

Today, from the user's seat: a counter ticks for ~6–10 s, then the entire
app appears at once. Structurally (`ContentView.swift:137–250`) the tree is
only assigned to `@Published` state *after* the walk finishes **and** after
one detached task runs `rollUpBoth` + `rollUpDescendantCounts` + QuickWins +
FileTypes + AnalysisSnapshot + Forgotten + Reviewables + Developer +
OldDownloads + LargeMedia — roughly ten sequential full passes over 1.8M
nodes before a single pixel changes.

Two independent fixes:

- **Stream the walk.** Publish a tree snapshot every ~400 ms with partial
  rollups so the treemap and Overview grow while scanning. This is by far
  the biggest *perceived*-speed win available, and it needs no scan-engine
  speedup at all.
- **Make catalogs lazy.** Forgotten / Reviewables / Developer / OldDownloads
  / LargeMedia each back exactly one destination. Compute on first visit
  (there is already a `refreshDeveloperCache()` precedent) instead of
  blocking first paint on all five. See C1 — measure this block first.

## B3. The IA has more screens than it has ideas

Fourteen destinations, of which **eight are ranked lists of files**:
Biggest Files, Biggest Folders, Top Sizes, Forgotten Files, Safe to Review,
Caches, Old Downloads, Large Media. They differ by filter and sort, not by
concept. This is parity-shaped IA — it mirrors DiskBuddy's menu rather than
a user's task — and every one of those screens is code and surface area we
maintain forever.

Proposal: **one Find surface** with filter chips (Large · Old · Duplicated ·
Cached · Media · Downloads) over a shared list component, plus the A6 query
box for anything the chips do not cover. Ship it behind the existing nav
first and measure which chips people actually use before deleting screens.
The sidebar collapses to Overview · Find · Clean · Explore · Developer ·
Apps · Snapshots — and each remaining item earns its slot.

This is the highest-leverage UX change in the list and also the most
disruptive, so it wants its own branch and its own decision-log entry in
`docs/ARCHITECTURE.md`.

## B4. Keyboard, for people who resent the mouse

Six `keyboardShortcut` calls exist today. Target:

- `⌘1`–`⌘9` destinations, `⌘R` rescan, `⌘K` palette (exists)
- `↑ ↓` / `j k` row navigation in every list, `Space` Quick Look
- `⌘↓` drill in, `⌘↑` up (exists in File Browser only — make it global)
- `⌘⌫` stage to cleanup, `⇧⌘⌫` open cleanup queue, `Enter` reveal in Finder
- Tab-to-focus through the inspector

A power tool that requires a trackpad for everything loses the audience in
Part A.

## B5. Drag a folder onto the window to scan

Zero `onDrop` / `NSItemProvider` in the codebase; the README already
promises "Finder-drag-to-scan". Accept a folder drop on the window and on
the Dock icon. Small, expected, and currently missing.

## B6. Progress that means something

`scannedCount` ticks and nothing else. Add items/sec, the directory
currently being walked, and bytes found so far. During a 10 s wait, "1.2M
items · 180k/s · ~/Library/Caches" is the difference between "it's working"
and "is it stuck?" Cancel exists in the model (`cancelScan`) — make sure it
is always reachable from the UI.

## B7. Menu bar extra (optional, but it is the weekly-open hook)

Free space, delta since the last scan, one-click rescan. This is what turns
DiskMap from a thing you remember when the disk is full into a thing that
tells you *before* it is. Pair with A1's project ageing. Keep it strictly
passive — no notifications by default, no background scanning without
consent.

## B8. Accessibility and window behavior

`docs/ACCESSIBILITY.md` marks phase 16 partial. Concrete gaps: font sizes
are hardcoded `.system(size:)` throughout, so text scaling does nothing;
the light-only lock also defeats Increase Contrast. Plus window state
restoration, remembering the last root, and multi-window.

---

# Part C — Scan speed

Current: workers = `min(CPU, 8)`, buffer 4 MB, single publisher thread.
Warm home ~1.8M items: **min 5.88 / median 5.94 / max 8.95 s**.

Honest framing first: **the walk is already I/O-bound** — the `sample`
capture in `docs/PERF.md` found an effectively empty call graph, and the
publisher-sharding experiment was correctly rejected on that evidence. So
the remaining wins are not "make the median 4 s". They are, in order:
perceived latency, not scanning at all, removing waste, and killing the
tail. Anyone attacking the median directly is optimizing the wrong number.

## C1. Measure the post-walk gap before optimizing anything

`docs/PERF.md` times the walk (~6 s), `rollUpBoth` (~30 ms) and layout
(~91 ms) — but **not** the eight catalog builds in between, which is
precisely the stretch between "scan finished" and "UI appears". That is an
unmeasured hole in an otherwise disciplined measurement log.

Add `DiskMapScanBench --phases` emitting walk / rollup / counts / each
catalog / layout separately. Predicted: ~10 sequential single-threaded
passes over 1.8M nodes is not free, and several are trivially parallel
across cores. **Do this first** — it either finds a second of latency
hiding in plain sight or it retires the hypothesis cheaply.

## C2. Incremental rescan via FSEvents — the 10 s → 200 ms change

Rescanning an unchanged home from scratch is pure waste, and rescanning is
the *common* case for anyone who opens the app more than once. We already
serialize a `FileTree` to disk (`Snapshot.swift`). Store the FSEvents
stream ID alongside it; on relaunch, replay events since that ID, mark the
touched directories dirty, and re-walk only those subtrees.

This is the single biggest real speedup available and it makes A1/B7
(project ageing, menu-bar delta) cheap instead of expensive. It is also the
most design work: event coalescing, dropped-event fallback to a full walk
(`kFSEventStreamEventFlagMustScanSubDirs`), and cross-checking that the
persisted tree matches the current volume. Its own milestone.

## C3. Free waste, already confirmed in the code

**A discarded `String` per directory.** In `BulkScan.publish()`:

```swift
let childPath = BulkScan.pathString(fromNULTerminated: childPathUTF8)
if CanonicalPath.shouldSkipDescend(absolutePath: childPath, scanRootPath: self.scanRootPath) {
```

`shouldSkipDescend` returns `false` immediately unless the scan root is `/`
or under `/System/Volumes`. For a home scan — the overwhelmingly common
case — we build and throw away a Swift `String` for **every directory**
(~200k of them), on the single publisher thread, which is the one thread
everything else queues behind. Hoist the root check to scan start into a
`Bool`, and skip the `pathString` call entirely when it is false.

**Zero-filled buffers.** Each worker allocates `[UInt8](repeating: 0,
count: 4 MB)` — 32 MB of pointless zeroing at startup across 8 workers.
`UnsafeMutableRawBufferPointer.allocate(byteCount:alignment:)` does not
zero.

**`broadcast()` where `signal()` would do.** Every `enqueue` and `submit`
calls `condition.broadcast()`, waking all 8 workers plus the publisher when
one runnable job appeared. Across ~200k directories that is a large number
of spurious wakeups and re-contentions on a single `NSCondition`. Use
`signal()` where exactly one waiter can proceed, and batch child enqueues
under one lock acquisition (already partly done — `jobs.append(contentsOf:)`).

**A `task_info` syscall on the publisher thread.** `ProcessMemory.current()`
runs every 4000 items inside `publish()`, in the middle of the hot path,
to maintain a stat we only need for benchmarking. Gate it behind the bench,
or sample it from a separate timer thread.

None of these will move the median much on their own — it is I/O-bound —
but they are all on the serialized publisher, which is the likeliest
contributor to C4.

## C4. Attack the tail, not the median

Identical back-to-back runs span 5.88 → 8.95 s (and 5.87 → 10.77 s in the
`utf8blob` session). That ~2× spread is worse for how the app *feels* than
the median is: a user who sees 6 s once and 11 s the next time concludes
the app is unreliable. `docs/PERF.md` already insists on min/median/max —
the natural next step is to make **p95 a tracked goal**, not just a
reported number, and to test C3's publisher-contention hypothesis against it.

## C5. Not worth it

- More workers — A/B already showed 12 is slower than 8 on this machine.
- `openat` fd handoff — tried, regressed to ~10 s flat, reverted.
- Publisher sharding — rejected on `sample` evidence; revisit only if C1/C3
  produce a profile showing a pegged publisher with idle workers.

Re-run all of these only with a profile in hand, not on intuition. The
existing perf log is unusually good about this; keep that bar.

---

# Suggested sequencing

Each of these is a branch, and each should land with `swift test` green and
a `TASKS.md` entry.

1. **Trust pass** — A4 (unreadable dirs) + A3 (volume reconciliation) +
   A7 (clone-aware reclaim math). Every number the app shows becomes
   defensible. Small, and it is a bug fix hiding in a feature list.
2. **Measure** — C1 phase timings. Cheap, and it decides how much of B2 is
   worth doing.
3. **Perceived speed** — B2 streaming first paint + lazy catalogs + C3's
   confirmed waste + B6 real progress.
4. **Dark mode** — B1, before more views exist to retrofit.
5. **Developer Storage v2** — A1 (manifests, rebuild cost, git state,
   project ageing, gitignore) + A2 (tool-native recipes). The flagship.
6. **CLI** — A5 + A8 export. Low cost, named in the PRD, unlocks CI use.
7. **Find consolidation** — B3 + A6 query language. Its own branch and
   an `ARCHITECTURE.md` decision-log entry.
8. **Incremental rescan** — C2. Its own milestone.
9. **Keyboard + drop + menu bar** — B4, B5, B7.

Items 1–3 are all cheap, all improve numbers the user already sees, and
none of them requires a design decision we have not already made.
