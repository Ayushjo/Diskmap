# Architecture

## Layout

- `DiskMapCore` — headless, no UI imports. Scanning, dedup, clone
  detection, cleanup staging. Should stay testable with plain `swift test`
  and reusable from a future CLI target.
- `DiskMapApp` — SwiftUI + AppKit glue.

## Decision log

### Struct-of-arrays tree instead of a class per file

A `class FileNode` with a handful of stored properties costs roughly 48+
bytes of object/ARC/isa overhead before a single field is stored, and every
`String` property is its own heap allocation. At a few million files that's
easily gigabytes of pure overhead for metadata that should fit in tens of
megabytes — almost certainly the exact category of bug DiskBuddy's "3.2 GB
→ 18 MB" memory-fix changelog line describes.

`FileTree` stores every field in its own packed array, indexed by `Int32`,
with folder/file names interned once instead of re-allocated per occurrence
(`node_modules`, `Library`, `.git` repeat constantly across a real
filesystem).

**Status:** measured on a release home scan. Packed node arrays are 38
bytes/node (`MemoryLayout`). After `FileTree.compact()` (TASK-002c):
62,334,592 bytes exact and 74,432,224 reserved at 1,640,384 nodes — the
remaining gap is allocator rounding, not `append`'s doubling. Before
compact the same structure reserved 117,522,144 at 1,640,392 nodes.
Process RSS is still larger than the arrays — see the home-folder
entry. That leftover gap is not another measurement ticket.

### Scanning does not materialize iCloud content

A disk scan has to read sizes. On a modern Mac those files may be
dataless (`SF_DATALESS` in `st_flags`, `ubiquitousItemDownloadingStatus
== notDownloaded`): listed, but the bytes are in iCloud.

**What was verified.** On a real evicted ubiquitous file (`st_blocks == 0`,
`SF_DATALESS` set, status `NotDownloaded`), reading
`.fileSizeKey` and `.totalFileAllocatedSizeKey` returned the cloud
logical size and allocated size 0. Two seconds later the file was still
dataless, `ubiquitousItemDownloadRequested` was still false, and
`isDownloading` was still false. Those two keys are metadata. Opening
the file or calling `startDownloadingUbiquitousItem` is what starts a
fetch; the scanner does neither. Content-tied keys (`contentAccessDateKey`,
`generationIdentifierKey`) are also not requested — Apple documents those
as able to fault a promised item in.

Because the size read is safe, an evicted file keeps both numbers
(allocated 0 is the truthful on-disk size) and is flagged
`NodeFlags.notDownloaded` so a later view can tell "in iCloud" from
"empty". A not-downloaded *directory* is recorded and then
`skipDescendants()` is called, so listing it cannot materialize the
folder. TN3150 notes that `stat`/`getattrlist` can still materialize an
intermediate folder that is itself dataless; that is inherent in walking
the path, and we do not add a content read on top of it.

**What could not be constructed.** `SF_DATALESS` is not settable from
userspace. `evictUbiquitousItem` on a file this process wrote into iCloud
Drive failed with `NSFileProviderError` -2008 ("cannot be evicted")
because the file never uploaded (this binary has no iCloud entitlement).
The decision function is replayed from
`Tests/Fixtures/evicted-ubiquitous-item.json`, captured from one real
evicted file (logical size 135,699, `totalFileAllocatedSize` 0,
`NotDownloaded`, `SF_DATALESS`, `st_blocks` 0). Path and filename are
not in the fixture. A live-file test exists and returns without failing
when no dataless file is present, so GitHub Actions does not need an
iCloud account. A home-folder scan flagged 17 already-evicted items.

**Status:** verified for the size-key question and the home scan.
Task: TASK-002.

### Home-folder scan

Debug (`swift run`, TASK-002), 2026-09-13: 1,657,572 enumerated items in
410.334 s. That run blended the walk and the retained tree into one
`resident_size_max` of 1,682,472,960. Do not use that number for either
question below.

Release (`swift build -c release` then `swift run -c release DiskMapApp
-- --scan ~`), same day, **before** an autorelease drain or compact:
1,653,983 enumerated items, 1,640,392 tree nodes (the difference is
skipped symlinks and unreadable items), 382.914 s, 17 not-downloaded.
Two `task_info` samples, not one blend:

- During the walk, max sampled `resident_size`: **5,016,731,648**.
- Immediately after `scan()` returned, tree retained, enumerator gone,
  before `rollUpSizes()`: **865,779,712**. RSS before the scan was
  67,371,008. The in-engine sample taken once `walk()` had returned and
  before the `Result` crossed the await was 865,632,256 (147,456 bytes
  lower).

`FileTree.packedNodeStride` is 38
(`5×Int32 + 2×Int64 + Bool + UInt8`). At 1,640,392 nodes, before compact:

| | Bytes |
|---|---|
| Packed arrays, exact count | 62,334,896 |
| Packed arrays, live `Array.capacity` | 117,522,144 |
| Interned name headers (`MemoryLayout<String>` × 655,686) | 10,490,976 |
| Interned name UTF-8 (measured) | 25,472,706 |

That reserved-minus-exact gap (55,187,248) is `Array`'s amortized
doubling, not live data. Post-scan RSS grew by 798,408,704. Subtract
the reserved arrays and the name bytes and **644,922,878** of that
growth was not the packed structure. A later `heap` on the still-running
process showed empty malloc regions still mapped — that sample was taken
after the treemap view attached, so it is not either number in the table
above.

The 5 GB walk peak was hypothesized to be autoreleased enumerator URLs
and resource values held until `walk()` returned. Tested the same day
(TASK-002c): `nextObject` / `resourceValues` run inside `autoreleasepool`
in batches of 4000, then `FileTree.compact()` copies the packed arrays
and the name table at count-sized capacity before `scan()` returns.
Same release launch, 1,653,975 items, 1,640,384 nodes, 373.357 s, 17
not-downloaded, RSS before the scan again 67,371,008. Hypothesis held —
both numbers dropped, the walk peak by far more:

| | Walk peak | After `scan()` |
|---|---|---|
| Before (no pool, no compact) | 5,016,731,648 | 865,779,712 |
| After (pool of 4000 + compact) | 417,415,168 | 473,972,736 |

The in-engine post-release sample and the caller's post-`await` sample
were the same this time (473,972,736). After compact, packed arrays were
62,334,592 exact and 74,432,224 reserved — 12,097,632 of allocator
rounding, not the old doubling slack. `Array(unsafeUninitializedCapacity:)`
does not guarantee `capacity == count`. Steady-state dropped by
391,806,976, more than compact can explain (~43 MB of reserved slack on
this run, ~55 MB on the previous node count), so draining the pool also
kept the walk's autoreleased objects from leaving pages mapped after
`scan()` returned. Remaining post-scan growth above reserved arrays plus
name bytes is still about 296 MB. That is recorded so it is not
re-measured as if it were unknown; it is not another ticket. Feature
work resumes at drill-down.

`scannedCount` updates from `applicationDidFinishLaunching`, not only
from SwiftUI `.task`. A first debug launch sat idle in `mach_msg` at 0%
CPU because a background-launched window never appeared and `.task`
never ran.

**Status:** release walk peak and post-scan RSS reported separately
(TASK-002b), then remeasured after a 4000-item autorelease drain and
`FileTree.compact()` (TASK-002c). The pool hypothesis was right. Do not
re-test it. The 373 s figure is the enumerator walk that those runs used.
The walk itself was replaced after that (see below). Task: TASK-002c.

### The walk is `getattrlistbulk`, not `FileManager.enumerator`

The 373 s home scan was not the packed tree. It was one `URL` and one
`resourceValues` call per file. `getattrlistbulk` returns a page of
names, types, sizes, mtimes, and flags in one syscall. Up to eight
workers each take a directory. Names are interned from the raw UTF-8 so
a repeated name does not allocate a `String`.

`SF_DATALESS` (`0x40000000`) is the not-downloaded flag. A dataless
directory is recorded and not opened, so listing it cannot materialize
the folder. Symlinks are not recorded and not followed (`O_NOFOLLOW`).
A directory we cannot open is recorded with no children. File logical
and allocated sizes were checked against `URL` resource values on a
fixture file (4 bytes logical, allocated size and modification day
matched). Record offsets are fixed to the attribute mask in
`BulkScan.swift`; they were read off a real buffer, not guessed.

**Status:** release home scan, 2026-09-14: 1,791,180 items, 1,758,058
nodes, **7.312 s**, 17 not-downloaded. About 245,000 items/s, versus
about 4,400 items/s on the enumerator. Walk peak RSS 426,229,760. The
old autorelease-pool RSS table was not re-measured. Task: the speed
pass after the views existed.

### APFS clone detection via `fcntl(F_LOG2PHYS)`

Apple doesn't expose a high-level "is this a clone of that" API. Hard links
share an inode and are detectable via `getattrlist`/`statfs` link-count
fields, but APFS clones use *different* inodes while sharing underlying
storage extents, so detecting them means comparing physical block offsets
directly via `fcntl`'s `F_LOG2PHYS` command. This is confirmed by an Apple
Developer Forums thread on exactly this question and a small community tool
built for it ([apfs-clone-checker](https://github.com/dyorgio/apfs-clone-checker)).

Once verified, this feeds two features: labeling clones as clones in the UI
(so a user isn't alarmed to "lose" space that's already shared), and
short-circuiting the duplicate finder — two files at the same physical
offset are guaranteed byte-identical, no need to hash either one.

**Status:** verified, TASK-005, macOS 15.5 SDK `sys/fcntl.h`.
`F_LOG2PHYS` is 49 and `F_LOG2PHYS_EXT` is 65. `struct log2phys` is
`#pragma pack(4)`, 20 bytes, device offset at byte 12 — not the 24-byte
Swift layout a matching field list produces (that misread two unrelated
8192-byte files as both offset 92; the packed struct returned
397016842240 vs 397018812416). Fresh sequential files of 4 KB through
8 MB were one extent, so a first-offset check happens to match a fresh
`cp -c`. It is not sufficient: a 4 KB write at offset 1 MB of an 8 MB
clone left `F_LOG2PHYS` reporting the original's device offset
(439726190592) while the extent map no longer matched. `areLikelyClones`
compares full `F_LOG2PHYS_EXT` maps.

That result is what `DuplicateFinder` is allowed to treat as
byte-identical. After a 64 KB partial-hash collision, a full extent-map
match is grouped with `sharesStorage` and is not hashed. Anything else
in the collision, including a clone overwritten past the 64 KB window,
is fully hashed. A shared group does not advertise `sizeEach` times
the extra copies as freeable space. `CleanupQueue.totalSize()` is
reclaimable bytes: one staged clone of a pair contributes 0; every
copy staged contributes `sizeEach` once. Content-hash duplicates still
contribute their own size. Excluded-path prefixes were not changed.

### Squarified treemap layout

Same algorithm (Bruls, Huizing, van Wijk, 2000) behind WinDirStat and
GrandPerspective — greedily builds near-square rows/columns so small files
stay legible instead of becoming slivers. Chosen over a simpler "slice and
dice" layout specifically because slice-and-dice degenerates badly on
directories with many small files, which is a common case for a real
Downloads or node_modules folder.

**Status:** verified. `squarify()` matches Bruls/Huizing/van Wijk 2000
section 3.1 (sizes [6, 6, 4, 3, 2, 2, 1] in a 6×4 rect). The first draft's
aspect-ratio used `shortSide²` as the container area, which is only right
for a square, and wrongly merged the last two size-2 items into one row.
Fixed; `swift test --filter SquarifiedTreemapTests` covers that layout
plus a no-gap/no-overlap tiling check. Task: TASK-001.

Drill-down does not rescan. `TreemapContainerView` caches the last
`[TreemapRect]` for the current node and canvas size, hit-tests the tap,
and sets `currentNode` only when that id is a directory. The breadcrumb
is `FileTree.ancestorIDs` (root first), each segment jumps back. The
header's Logical / On Disk control switches which `rollUpSizes(basis:)`
array the rectangles and the breadcrumb size use. A normal directory
does not add its own `fileSize` (directory metadata). A not-downloaded
directory with no children does, because its cloud size was never
expanded into descendants. Task: TASK-003, TASK-004.

### App leftover matching is unavoidably heuristic

No Apple API enumerates "everything this app touched." Every open-source
uninstaller in this space (AppCleaner, Pearcleaner) does what
`AppLeftoverFinder` does: search known Library locations for items whose
name contains the app's bundle identifier, falling back to a fuzzy
display-name match when no bundle ID is available. This is why cleanup is
always staged for review rather than automatic — the matching will
occasionally be wrong, and staging is what makes that safe instead of
scary.

**Status:** implemented, needs real-world false-positive tuning. Task:
see SETUP.md — this one specifically needs a human judgment call, not just
more code.

### Distribution: notarized outside the App Store, not sandboxed

DiskBuddy ships this way, and it's the right call here too — a disk
analyzer that has to request per-folder access under the App Sandbox isn't
really doing its job. Trade-off: no App Store discovery, and the user has
to click through an unnotarized-app warning once (or we notarize, which
needs a paid Apple Developer account). See `docs/PRD.md` non-goals.

**Status:** not started. Requires TASK-020 onward.

### Snapshots are a versioned binary file, not SQLite

A scan is already packed arrays plus an interned name table. SQLite would
be a second data model for the same bytes, and a query engine we do not
need to load a scan or diff two scans by folder path.

The file is little-endian. Magic `DMAP`, version `UInt32` 1, timestamp
seconds, root path, node count, name-table count, then the packed arrays
(`nameIndex`, `parent`, `firstChild`, `nextSibling`, `logicalSize`,
`allocatedSize`, `modifiedDay`, directory flags, node flags) and the name
table. One file per scan, under Application Support `DiskMap/snapshots`,
named by timestamp. Listing reads that header only, so a saved home scan
is not decoded just to show a date.

The diff matches directories by standardized path. A folder that exists
on only one side is a full grow or shrink, not a missing row. Reopening a
snapshot in the treemap can wait; the diff view is the acceptance.
Offline. No networking.

**Status:** implemented (TASK-018, TASK-019).

### Search indexes the name table, not the nodes

Names are interned: 1.8M scanned items share ~10⁵ unique strings.
`FileSearchIndex` lowercases the name table once at build, then a
counting sort groups node ids by name id — so a query is `contains` over
the table plus a gather over only the nodes whose name already matched,
and the common case (a needle with few matching names) never touches
most nodes at all. Ranking keeps the top N by rolled-up size with a
bounded insert instead of sorting the match set, so pathological
needles stay cheap too. Result: single-digit-millisecond queries on a
million-node tree, versus a per-node substring scan on every keystroke.

The alternative — building paths up front — would spend O(depth) string
work per node to answer a question about names only. Paths are built on
demand for the ≤300 shown results.

**Status:** implemented. `FileSearchIndex` is built once per scan and
shared by the Search page.

### Quick Wins patterns are categorized data, not a flat list

The pattern file is `{"categories": [...]}` — each category carries an
id, display title, a plain-language note about why its data is
regenerable, plus the same name/suffix patterns as before. Grouping is
what makes the Developer page possible: hits are attributed to the first
category that claims them (name lookups resolve once per unique interned
name, not once per directory), and each category explains its own
caveat — e.g. deleting `CoreSimulator/Devices` removes the simulators,
not just their cache. A flat legacy file still decodes as one category,
so a hand-edited pattern list keeps working.

**Status:** implemented. Flat `QuickWins.find` is the union of all
categories; `findCategorized` backs the Developer page.

### Whole-tree view queries are once-per-scan state, not computed properties

Quick Wins, age buckets, and untouched files were computed properties —
every render (each checkbox toggle) re-walked the entire tree on the main
actor. Views now compute them in `.task(id: model.scanID)` detached from
the main actor and cache the result; a new scan is the only thing that
recomputes. The same applies to snapshot save/load/diff, duplicate
candidate collection, and app-leftover lookup — all detached, with a
staleness guard so a superseded selection can't write its result.

**Status:** implemented.

## Adding a new decision

When you make a non-obvious architectural choice, add an entry here:
what was chosen, what the alternative was, why, and current status. Keeps
this file the source of truth instead of scattered PR descriptions.
