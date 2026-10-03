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

The file is little-endian. Magic `DMAP`, version `UInt32` 2 (v1 still
loads; missing `createdDay` fills zeros), timestamp seconds, root path,
node count, name-table count, then the packed arrays (`nameIndex`,
`parent`, `firstChild`, `nextSibling`, `logicalSize`, `allocatedSize`,
`modifiedDay`, `createdDay` from v2, directory flags, node flags) and the
name table. One file per scan, under Application Support `DiskMap/snapshots`,
named by timestamp. Listing reads that header only, so a saved home scan
is not decoded just to show a date.

The diff matches directories by standardized path. A folder that exists
on only one side is a full grow or shrink, not a missing row. Reopening a
snapshot in the treemap can wait; the diff view is the acceptance.
Offline. No networking.

**Status:** implemented (TASK-018, TASK-019).

### Explore is one shell; viz modes are not pages

DiskBuddy’s left chrome (scan actions, Recent, Disk Storage, Current View,
Quick Wins, File Types) and right Inspector stay put while the center canvas
swaps among Treemap / Sunburst / Flame / Bubbles / Mind Map / Top Sizes /
Age Map / Folders. Top nav is Explore | Duplicates | Applications | Monitor
(stub) | Snapshots — Quick Wins is not a destination. Shared cream
`#FAF5EC` and ink `#1C1B17` tokens live in `DesignSystem.swift`.
`VolumeStats` and `FileTypeCatalog` are DiskMapCore; ChartLayout’s
`otherFraction` is an optional parameter only (depth slider). No birthtime
on `FileTree`, so Inspector Created is "—" until a deliberate schema task.

**Status:** implemented (TASK-030). Treemap is the skin checkpoint; other
seven modes reuse existing canvas views inside the same shell.

### createdDay mirrors modifiedDay (birthtime days)

`FileTree.createdDay` stores birthtime as days since epoch, same packing as
`modifiedDay`. Live scans use `getattrlistbulk` (`BulkScan`), not per-file
`resourceValues` — so creation is `ATTR_CMN_CRTIME` on the same attribute
mask / syscall as `ATTR_CMN_MODTIME` (one more attr, same bulk call). Snapshot
codec is version 2; version 1 files still decode with createdDay zeros.

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

### Scan workers default to eight; paths stay UTF-8 bytes

A dedicated publisher thread owns `FileTree` mutation while N workers run
`getattrlistbulk`. Warm A/B on a ~1.8M-item home folder (2026-09-14):
8 workers median 6.038 s, 4 workers 8.861 s, 12 workers 9.911 s. Default
is therefore `min(CPU, 8)`, overridable with `DISKMAP_SCAN_WORKERS`.

Child directory jobs carry NUL-terminated UTF-8 path bytes for `open(2)`
instead of `String` joins on the publisher hot path. An `openat` fd-handoff
design was measured and rejected (flat ~10 s). Per-worker attribute buffers
default to 4 MB (`DISKMAP_SCAN_BUFFER_MB`). Measurement playbook:
`docs/PERF.md`.

**Status:** implemented (TASK-024, TASK-025).

### Post-scan rollup is one walk for both size bases

Logical and allocated totals are filled together by `FileTree.rollUpBoth()`.
ContentView already caches both arrays for the size toggle; this only
removes a second full tree walk (~30 ms saved on a home scan — small vs
the walk, free correctness-wise).

**Status:** implemented (TASK-025).

### Name storage (2026-09-13)

Unique names live in a packed UTF-8 `nameBlob` with `nameOffset`/`nameLength` tables. Open-addressed intern compares raw UTF-8; `String` materialization is for UI and Snapshot encode only.


### Nodes carry file identity; the walk stays on one volume (2026-09-25)

**Chosen.** `FileTree` gains one `[UInt64]` `fileID` array (ATTR_CMN_FILEID).
Hard-link-ness rides in the already-declared, previously-never-set
`NodeFlags.hardLink` bit rather than a second array. Device id is requested
but **not stored** — it is consumed in `BulkScan.publish` to decide descent
and then discarded.

**Alternatives rejected.**
- *Keep identity out of the scan and resolve sharing only at cleanup time.*
  That fixes the confirmation dialog but leaves Biggest Folders, the treemap
  and every rollup counting an N-named inode N times. Identity is a property
  of the data, so it belongs in the data.
- *Store link count as its own `[UInt32]`.* 7 MB at home scale for a value
  that is 1 for essentially every node. One free flag bit carries it.
- *Store device id per node.* Another 7 MB for something only the descend
  decision reads.

**Why the mask includes `ATTR_DIR_LINKCOUNT`, whose value we distrust.**
Requesting only `ATTR_FILE_LINKCOUNT` makes file records 4 bytes wider than
directory records, which breaks the single-offset-pair `parse()` that swaps
meaning by `objType`. Adding the directory counterpart makes both sections
20 bytes at offset 88 and keeps `parse()` branch-free. Its *value* is not
usable: measured on APFS, a directory with three children and `st_nlink == 5`
reports `ATTR_DIR_LINKCOUNT == 1`. Only `ATTR_FILE_LINKCOUNT`, and only for
files, is trusted. Evidence: `docs/perf-results/attr-probe.txt`.

**Offsets were measured, not derived.** The `AttrProbe` target builds a
fixture with known `lstat` values and reports every offset whose bytes match
ground truth. Adding DEVID (+4), FILEID (+8) and LINKCOUNT (+4) moved every
later field and took `fixedPrefix` from 92 to 108. Re-run `swift run AttrProbe`
after any mask change and update `docs/perf-results/attr-probe.txt`; do not
hand-edit the offsets in `parse()`.

**Mount containment.** A directory on a different device is recorded (so it
stays navigable) but not descended, unless `crossMounts: true` is passed.
Before this, a `/` scan silently absorbed every mounted volume into the
totals. It also makes `fileID` unique across a scan, which the hard-link
rollup correction depends on — inode numbers are only unique per volume.
`ScanEngine.Result.crossMountSkipCount` reports how many mounts were held
back so Overview can say so rather than quietly under-reporting.

**Free win taken alongside.** `shouldSkipDescend` can only return true when
the scan root is `/` or under `/System/Volumes`, but `publish` was building
and discarding a path `String` for every directory to ask. That check is now
hoisted to `CanonicalPath.mayContainFirmlinkTwins`, evaluated once per scan,
so a home scan no longer allocates ~200k throwaway strings on the single
publisher thread.

**Status:** verified. `swift test` 108 green, including the suite's first
hard-link coverage (`ScanIdentityTests`) asserting two names resolve to one
inode and both carry the flag. Snapshot format bumped to v3; v1 and v2 still
decode, with identity reading 0 ("unknown").

### Hard links are charged once, to a path-elected name (2026-09-25)

**Chosen.** `rollUpSizes` / `rollUpBoth` charge a multiply-linked inode to
exactly one of its names; every other name contributes 0. The suppression is
applied inside `ownSize`, so the existing post-order walk produces the
corrected totals directly — there is no second pass and no subtract-from-
ancestors fixup.

**Why suppress the node itself, not just its ancestors.** Charging the
duplicate name its own size while withholding it from the parent would break
the tree invariant that a directory total equals the sum of its children.
`SquarifiedTreemap` and every other layout lays children out inside the
parent's rect, so a violated invariant is an overflowing treemap, not just a
cosmetic discrepancy. A duplicate name therefore reads 0, and
`NodeFlags.hardLink` is on the node so the UI can say "another name for an
already-counted file" rather than appearing to lose bytes.

**Election is by lowest path, not lowest node id.** Node ids are assigned in
publisher order and sibling lists are built by prepend, so both depend on how
the scan's worker threads interleaved — neither is stable between two scans of
an unchanged disk. Electing by node id would make a snapshot diff report a
large file moving from one folder to another when nothing changed. Paths are
stable, and they are built only for flagged nodes (about 0.7% of a real home
tree), never on the rollup hot path.

**A file linked outside the scan root keeps its full size.** Grouping is by
inode *within the tree*, so `st_nlink == 2` with only one name inside the
scanned subtree forms a group of one and is not suppressed. Suppressing it
would under-report real usage — the bytes genuinely are in this tree.

**Cost.** One linear pass over the `flags` byte array per rollup. When nothing
is flagged the pass returns `nil` and allocates nothing, so trees without hard
links (and every v1/v2 snapshot, which carries no identity) behave exactly as
before.

**Clones are deliberately NOT handled here.** An APFS clone has a *different*
inode and can only be detected by comparing physical extents with `fcntl`,
which is far too expensive to run tree-wide. Clone-aware reclaim belongs at
the cleanup boundary, over the staged set only — see TASK-038.

**Status:** verified. 116 tests green, including `HardLinkRollupTests`, which
covers cross-folder links, insertion-order stability, inodes linked outside
the tree, same-size-but-distinct inodes, and a real `link(2)` end-to-end scan.

### The walk is finished only when the publisher is also idle (2026-09-25)

**A pre-existing correctness bug, found while stabilising the trust pass.**
Not introduced by TASK-036/037: measured on the unmodified parent commit
(8190439), the existing `ScanEngineFixtureTests` fixture failed **3 runs in
15**. It had simply never been characterised — grep of `docs/` and `TASKS.md`
for "flaky"/"race" before this returned nothing.

**The window.** `signalWorkLocked` declared the walk over when
`inflight == 0 && jobs.isEmpty && batches.isEmpty`. It did not account for a
batch the publisher had already taken off `batches` but not yet turned into
nodes and child jobs — the publisher unlocks for the whole of `publish()`.
So:

1. The publisher pops the batch for a directory and unlocks. `batches` is now
   empty; that directory's children are not yet in `jobs`.
2. A worker fails to `open()` an unreadable sibling and calls what is now
   `noteUnopenedDirectory`, which drops `inflight` to 0 **without** ever
   adding a batch.
3. All three queues read empty, `finished` is set, every worker exits.
4. The publisher then appends the child jobs and exits too. Nobody scans them.

The scan returned a tree **missing an entire subtree, with no error raised
anywhere** — the walk reported success and the totals were silently short.

**Why unreadable directories are the trigger.** `noteUnopenedDirectory` is the
only path that decrements `inflight` without producing a batch, so it is the
only way the queues can all read empty while real work is outstanding. That is
why the one fixture containing a `chmod 000` directory was the test that
flaked, and why this would bite hardest on exactly the scans that matter — a
full-disk or `~/Library` walk without Full Disk Access, where unreadable
directories are everywhere.

**Fix.** `State.publishing` counts batches in the publisher's hands. It is
incremented under the lock *before* the publisher unlocks, decremented only
after the children are appended, and added to the termination condition.

**Status:** verified by repetition, since a single pass passes most of the
time either way. Full suite: **8 failures in 30 runs before** (3/15 on the
untouched parent commit, 5/15 mid-trust-pass) versus **1 in 70 after**.
`ScanTerminationTests` is the regression guard — it scans a deep chain beside
four unreadable siblings 40 times and asserts both that the deepest leaf
survives and that the node count never varies between identical scans.

### The scan runs on dedicated threads, not shared pools (2026-09-28)

**A second pre-existing hang, separate from the termination race above.**
`ScanEngine.scan` ran the blocking `BulkScan.walk` inside `Task.detached`
(Swift's cooperative pool) and the walk's workers and publisher on
`DispatchQueue.global(qos: .userInitiated)`. Both pools cap how many threads
may run at a QoS, and the cooperative pool assumes its threads never block —
the kernel keeps counting a cooperative thread parked in `group.wait()` as
active. With more scans in flight than cores, every slot was held by a walk
waiting on workers that could never be scheduled. Sampled from a hung test
process: 11 threads in `_dispatch_group_wait_slow` inside `BulkScan.walk`,
**zero** worker threads, **zero** publisher threads — permanently.

**Chosen.** The coordinator, each worker and the publisher run on their own
`Thread` (`BulkScan.startScanThread`, QoS `.userInitiated`, named
`DiskMap.scan.*` so they are identifiable in `sample`). `ScanEngine.scan`
bridges back to async with a `CheckedContinuation`, so no Swift-concurrency
thread is ever blocked by a scan. These threads are real pthreads outside both
capped pools. Ten short-lived threads per multi-second scan is noise.

**Alternative rejected:** keep GCD but move only the coordinator off the
cooperative pool. GCD's global queues cap at ~64 threads; several concurrent
scans at 10 blocked threads each can still exhaust that, just less often.

**Why it matters in the app, not just tests.** `cancelScan` only bumps a
generation counter — the old walk keeps running to completion. Cancel and
rescan a few times and several walks are alive at once, each previously
parking a cooperative thread the rest of the app's `Task.detached` work
(layouts, duplicate candidates, catalogs) also needs.

**Status:** verified. `ScanTerminationTests.manyConcurrentScansAllFinish`
runs (cores × 2 + 4) scans at once: it hung for over 10 minutes on the unfixed
commit with the same thread signature, and passes in ~0.3 s with the fix. A
regression shows up as a *hung* suite, not a failed test — Swift Testing's
time limit runs on the starved pool and cannot fire.

### Clone detection flushes before reading extents (2026-09-28)

**A third pre-existing bug, surfaced by a flaky `CloneDetectorTests` case.**
APFS allocates a clone's copy-on-write block when dirty pages are *written
back*, not at `write()`. Until then `F_LOG2PHYS_EXT` reports the old shared
physical extent for a range whose bytes have already changed. So a clone
edited seconds before a duplicate scan still produced an identical extent map,
`areLikelyClones` said yes, and `DuplicateFinder` put the two files in a
"shared-extents" group — **presented as identical without ever being hashed**.

**Measured, not inferred.** Under concurrent load, with the writer not
flushing: 18 of 320 edited 8 MB clones and 22 of 200 edited 64 KB clones were
wrongly reported as clones. With the writer flushing: 0. With the *reader*
calling `fsync` on its own read-only descriptor before mapping: 0 of 320. The
reader-side result is the one that matters — DiskMap never controls the writer.

**Chosen.** `extentMap` calls `fsync(fd)` after `fstat`. It writes out data the
kernel was already going to write within seconds; it changes no contents and
no metadata. If `fsync` fails the map is `nil`, which `areLikelyClones` treats
as "not proven clones" — the safe direction, because the caller then hashes.

**Alternative rejected:** treat any file modified in the last N seconds as
"not a clone". Writeback delay is not bounded (memory pressure stretches it),
so any N is a guess, and it silently stops detecting real clones of files that
were just copied with Finder's Duplicate.

**Test note.** The regression test must clone with `/bin/cp -c`. Calling
`clonefile()` in-process never reproduced the stale map (0 of 600 on the
unfixed code); the `cp` path did every time (15–22 of 200). The process launch
shifts writeback timing into the window that matters. A test that "passes" on
the unfixed code proves nothing, so this was checked in both directions.

### Reclaim figures come from APFS's own accounting, derived by the queue (2026-09-28)

**The problem was structural.** `CleanupQueue` already had clone-aware
grouping, but only `DuplicatesView` ever supplied the hint it needed. Every
other staging surface passed the defaults, so clones and hard links counted at
full size in the same "This will free about X" dialog, and the post-commit
receipt re-inflated them again. The dialog also claimed moving to the Trash
"frees" space — it frees nothing until the Trash is emptied.

**Chosen: the queue derives sharing itself** (`StorageSharing`), so no caller
can forget. It profiles each staged path — one `getattrlist` for a file, one
bulk walk for a folder — and the queue-wide estimate applies three rules:
ordinary data counts its `ATTR_CMNEXT_PRIVATESIZE`; a hard-linked inode counts
once and only when every name is queued; a pure-clone family (same
`ATTR_CMNEXT_CLONEID`) counts its shared blocks once and only when all
`ATTR_CMNEXT_CLONE_REFCNT` members are queued. A file inside a queued folder is
counted by the folder, not twice.

**Deviation from the plan.** The plan said pairwise `CloneDetector` over the
staged set with memoised extent maps. The SDK turned out to expose the exact
quantities instead, including blocks held by local snapshots, which extent
comparison cannot see. `CloneDetector` still backs duplicate discovery.

**Semantics were measured, not read** (`SharingProbe`,
`docs/perf-results/sharing-probe.txt`): PRIVATESIZE is 0 for pure clones, only
the diverged bytes for an edited clone, and *ignores hard links* (both names
report full size). REFCNT counts the family including itself and follows
deletions. A partially edited clone leaves its family, so the bytes it still
shares are reported as unattributed and the figure becomes a lower bound
rather than a guess.

**Two traps found only by testing on real volumes:**
- Directory entries in a bulk read *omit* the file attributes even with
  `FSOPT_PACK_INVAL_ATTRS`; a length check sized for file records rejected
  them and silently dropped whole batches.
- FSKit-mounted ExFAT sets the "returned" bits for all four extended
  attributes and fills them with zeros. Trusting the bitmap would have reported
  "frees nothing" for every file on an external drive. Extended attributes are
  used only when `f_fstypename` is `apfs`.

**Staging never blocks.** Measuring a large folder is slow (single-threaded
walk: ~9.6 s for a 325k-file `~/Library/Caches`, ~27 s for `~/Library`), so an
item is queued immediately and measured on a dedicated thread. Until then the
estimate is flagged `isCalculating`, the row says "measuring…", and **Move to
Trash is disabled** — the destructive action is never offered on a provisional
figure. `commitReport` also waits for measurement, because a moved item can no
longer be measured. Making the walk itself parallel is left open.

**Status:** verified on APFS and on a real FSKit ExFAT volume. 140 tests green,
12/12 stability runs clean.

### Per-screen catalogs are built on first visit (2026-09-28)

**Measured first** (TASK-042): after the walk, the app built every screen's
catalog before first paint — ~8.9 s on a home scan, longer than the walk
itself. TASK-069 cut the catalogs' own cost; this makes first paint wait only
for what Overview and Explore need.

**Chosen.** `PreparedScan` carries rollups, counts, QuickWins, FileTypes and
the `AnalysisSnapshot`. Forgotten, Reviewables, Developer, Old Downloads and
Media are built by `ScanModel.ensureCatalog` when their screen appears, off the
main actor. `readyCatalogs` records what is built for the current tree and
basis — a separate fact from "has items", which the old `isEmpty` guard
conflated. `catalogGeneration` bumps on any invalidation (new tree, basis
toggle); screens key `.task(id:)` on it so an already-open screen rebuilds.

**Alternative rejected:** keep eager builds but move them after first paint in
the background. It would still spend seconds of CPU on screens most sessions
never open, and it contends with the user's first interactions.

**Status:** real app, 2.25M-item home: walk-finished to first paint 0.92 s.

### Dark mode: adaptive chrome, fixed data (2026-09-28)

**Chosen.** Surface, text and semantic tokens are AppKit dynamic colours
(`DiskMapTheme.adaptive`), so the app follows the system appearance. Data
colours — treemap/chart tiles, file-kind and age palettes — are fixed, and text
drawn on tiles uses a fixed dark `tileLabel`. Translucent tile fills are made
opaque by compositing against the light canvas (`DiskMapTheme.wash`).

**Why data does not adapt.** A tile's colour is its identity across screens
and sessions; re-tinting it per appearance changes what the user learned
("Downloads is pink"). And adapting the label colour instead broke legibility:
`ink` turns light in dark mode, which put light text on pastel tiles.

**Why opaque washes.** `color.opacity(x)` over a dark canvas darkens the fill,
so the fixed dark label lost contrast on bubble containers and deep rings.
Found by rendering every Visualize mode in both appearances, not predicted.

**Verification** is visual by nature: the snapshot harness renders any screen
in `light`, `dark`, `hc-light` or `hc-dark` from inside the app.

### Developer Storage v2: decisions from the scan tree, git from disk (2026-09-28)

**Chosen.** Everything that decides whether a developer folder can go is
computed from the existing scan tree plus a few small file reads: manifests
and lockfiles from folder child names; git state from `.git/config`, loose and
packed refs; ignored bytes by evaluating `.gitignore` files over the tree. No
`git` subprocess (offline promise; no dependency on the user's PATH), no
second walk of the disk.

**Rejected: calling `git`.** It would give exact ahead/behind counts and
uncommitted-change detection, but spawning a process per repository is slow,
depends on git being installed, and git hooks/config can run arbitrary code.
The cost is honesty in the copy: "differs" cannot distinguish unpushed from
not-yet-pulled, and uncommitted changes are not checked — both stated in the UI.

**Recipes are shown, never run.** `CleanupQueue.commit()` remains the only
removal path. Where the Trash damages a tool's own state (Docker's disk image,
simctl's device store) the Add to Cleanup action is withheld in Developer
Storage and the queue warns if such a path is staged elsewhere; the queue does
not refuse it — the user may genuinely be removing Docker.

**Nothing inside an application bundle is a developer artifact.** Found on the
real scan: node_modules inside staged app updates were offered as reclaimable.

### The CLI is a second front end, not a second engine (2026-09-28)

**Chosen.** `diskmap` depends only on `DiskMapCore` and calls the same scan,
catalogs, duplicate finder and exporters as the app. It reads only — there is
no `clean` command; removal stays the app's staged, Trash-only queue.

**Output contract.** stdout carries exactly the result (one JSON document with
`--json`); everything else — progress (only on a TTY), denied-folder warnings,
the engine's summary line — goes to stderr. Exit codes are the CI contract:
0 ok, 1 `check` threshold exceeded, 2 usage, 3 unreadable path.

**Units.** `GB` means 10⁹ because that is what Finder and the app display;
`GiB` is 1024³. A `--fail-over 50GB` that disagreed with Finder by 7% would be
a bug report waiting to happen.

**Exports stream.** Formats are written as the tree is walked, in chunks, with
paths carried down the recursion. The ncdu format is never filtered: ncdu
computes folder totals from the entries it is given, so a filtered file would
show wrong totals rather than fewer rows.

**The app writes exports in place** rather than via a temp file it would later
have to delete: the save panel already asked before overwriting, and keeping
the app free of any `removeItem` call keeps rule 1 greppable.

### One Find surface, next to the old screens (2026-09-29)

**Chosen.** A single Find screen over the whole scan, driven by one query
language (`FileQuery`) shared with ⌘K and `diskmap find`. Chips are not
filters with their own state: each toggles one token in the query text, so
what the list shows is always exactly what the box says, and any chip
combination can be typed, copied, or run from a terminal.

**Not yet: deleting screens.** Eight destinations are ranked file lists that
differ by filter (Biggest Files, Forgotten, Old Downloads, Large Media, …).
Find can express most of them, but some carry their own judgement — Safe to
Review's app grouping, Duplicates' content hashing, Old Downloads' installer
logic — that a query does not reproduce. Find ships beside them; chip use is
counted in local preferences (never sent anywhere) so the decision to retire
a screen rests on use, not on taste.

**Defaults chosen for honesty over cleverness.** Size, age, extension and
kind imply files, because folder totals nest and `size>1GB` over folders
lists every ancestor of one big file. Unknown `key:` text stays a plain word.
Bad values are shown and ignored rather than failing the whole query.
`in:caches` means folders named Caches, DerivedData or `.cache` — the Caches
screen's rule plus the XDG cache folder developer tools use.

**No paths on the hot path.** Matching runs per distinct name on raw UTF-8
and per node on integer arrays; a path is built only for the rows shown.
The byte-level matcher declines anything non-ASCII, falling back to String
comparison, so speed never changes an answer.

### Rescans start from the last scan; FSEvents is a hint, the disk is the truth (2026-09-29)

**Chosen.** Replay FSEvents history since the last scan, re-list only the
folders it names (plus their parents), walk anything new or flagged
"must scan subdirs", and copy the rest of the previous tree. Everything the
history cannot vouch for — a reset event database, dropped or wrapped
events, a moved root, too many changes, too many updates in a row, an old
full walk — falls back to a full walk, and the UI says which happened.

**Verification is built in, not assumed.** Each update re-reads the root and
64 random unchanged folders and compares them with the tree; any
disagreement means a full walk. The FSEvents docs are explicit that the
history can be incomplete; this is the "periodic validation" the spec asks
for, run on every update rather than on a timer.

**Why parents are re-listed.** A folder's own dates and size fields come
from its parent's `getattrlistbulk` records, and the parent gets no event
when only the folder's contents change. Re-listing one level up keeps those
fields exact at the cost of one more directory read per change.

**Why an event barrier.** Event ids are assigned ~0.1 s after the change
reaches the kernel. Writing a marker and waiting for its event (FIFO
delivery) guarantees every earlier change is in the replay; without it,
changes made in the last moment appeared one update late.

**Cache shape.** One overwritten slot per client instead of one file per
folder: bounded disk use, and no pruning — which would have been a second
code path that deletes files, against rule 1.

**Rejected: a live watcher.** It would make updates near-instant, but means
running in the background, which the product promises not to do without
consent. Replay on demand gets the same answer when asked.

### Native affordances stay passive and go through the same paths (2026-09-29)

**Keyboard.** One modifier gives every list the same keys, and ⌘⌫ calls each
list's existing staging function rather than a new one — so the rules that
decide what may be staged (protected paths, recipe-only tools, app-bundle
contents) apply unchanged, and the result is still only a queued item.

**Drop and open.** Folders only; files and app bundles are refused rather
than guessing a parent. The app claims folders at `LSHandlerRank None`: it
can open them, it never becomes the default for them.

**Menu bar.** Informational and on demand. It never scans by itself and
never notifies; the only periodic work is a statfs(2) every five minutes so
the icon can say when space is low. It lives only while the app runs and
can be hidden from the app menu.

**Resources are looked up in the app first.** SwiftPM's generated
`Bundle.module` does not know about `Contents/Resources`, so a packaged app
silently fell back to the build folder's absolute path. `DiskMapResources`
checks the app's Resources first and keeps `Bundle.module` for `swift run`
and tests.

### Snapshot compare aligns trees lazily and reports hotspots (2026-09-29)

**Chosen.** Two snapshots are compared by walking both trees together by
child name, one folder at a time, on demand. Every level's rows sum to the
folder above them, and the first screen needs only the root's children.
"Hotspots" descend from the root while at most three children explain 80% of
a change (same direction), and stop at a file, at a folder that is new or
gone as a whole, or at a folder whose change is spread — so the list names
where a change happened instead of every ancestor of it.

**Rejected: a flat list of every changed folder.** It needs a path per
folder of both trees (52 s on a real home) and repeats one change at every
level above it.

### Multi-selection reads held keys (2026-09-29)

SwiftUI runs a button's action after the click has been dispatched, so
`NSApp.currentEvent` is usually another event; the modifier keys held at the
time of the action are the reliable source. The snapshot harness supplies
its synthetic clicks' modifiers through a debug-only seam.


### Two search engines coexist, by choice (2026-10-03)

PR #16 added Search (`FileSearchIndex`: an interned-name index built once
per scan, substring match as you type, biggest hits first), while Find,
⌘K and the CLI use `FileQuery` (a small query language over size, age,
kind, extension and location). They answer different questions — "where
is the thing called X?" versus "what matches these conditions?" — so both
pages stay, side by side in the Find section of the sidebar. Revisit once
there is usage evidence (chips vs. pages); merging them would mean teaching
`FileQuery` an index for bare-name terms, not deleting a page.

PR #16's flat Quick Wins categories are kept as **Regenerable Data** next to
Developer Storage: the first groups pattern hits by ecosystem straight from
`quick-wins-patterns.json`; the second judges projects (rebuild cost, git
state). Both stage through `CleanupQueue.stage()`.

Duplicates now hash only files whose size collides with another file's
(`DuplicateFinder.sizeCollidingCandidates`); hard-link dedup and
cancellation stay in the same walk.

### Overview categories depend on what was scanned (2026-10-03)

Folder names are a meaningful split only at the top of a home folder (Library,
Downloads, Documents…) or a disk (System, Users, Applications). For any other
root the children are arbitrary, so `AnalysisSnapshot` splits by file type
instead (`CategoryMode.folder`), reusing the File Types totals the scan already
computes. A root that *looks* like a home (two of Library/Downloads/Documents/
Desktop) — an old account on a backup drive — is treated as one. Rows always
add up to the scanned total; "Other" is what no type claims, never padding.

### APFS clones: a sparse side table, one member carries the blocks (2026-10-03)

A file copied by Finder, `cp -c`, or tools that clone on write (pnpm, uv,
Xcode) shares every block with the original until one of them is edited. The
walk used to charge each copy its full allocated size. On the development
machine's home folder that counted **80.1 GB** more than once (266,344
families with more than one member inside the home; 884k clone rows).

**What the scan reads.** `getattrlistbulk` can return
`ATTR_CMNEXT_CLONEID` and `ATTR_CMNEXT_CLONE_REFCNT` (and `PRIVATESIZE`) with
`FSOPT_ATTR_CMN_EXTENDED`. Each mask has its own record layout, measured by
`AttrProbe --extended [--refcount-only]` (`docs/perf-results/attr-probe-ext.txt`)
— dropping PRIVATESIZE moves CLONEID from 116 to 108. `SharingLayout` holds
one measured layout per mask. Only APFS (by `f_fstypename`, because FSKit
ExFAT claims these attributes and returns zeros), and only on the scan
root's own device.

**Refcount is enough for families.** Members with refcount > 1 had no
private bytes at all (0 of 884k): APFS gives an edited clone a new clone id
and drops it from the family. So the cheaper request (CLONEID + REFCNT) finds
every family; PRIVATESIZE adds only the edited copies that still share some
blocks with a family they left (328 files, 38 MB here), which are counted in
full and reported, never guessed away.

**Storage.** A sorted side table on `FileTree` (node, clone id, private
bytes, refcount) — no new per-node array, 24 bytes per clone row — and the
`apfsClone` flag bit (defined since TASK-001, set for the first time now).
Snapshot codec v4 appends it; v1–v3 decode with `hasSharingInfo == false`
("unknown", not "none"). Quick rescans copy rows with their nodes and refuse
to mix a tree with clone facts and one without.

**Rollups.** Per family (deduplicated by inode, so a hard-linked clone is one
member), the member with the lowest inode carries its allocated size; the
others carry their private bytes. Lowest inode, not lowest path as for hard
links: clones each have their own inode, which is stable between scans, and
building ~900k paths would cost seconds. Logical sizes are unchanged.

**Why it is a setting, off by default.** Asking for CLONEID + REFCNT made a
home walk +14% slower at the median and +22% at p95 (8 alternating rounds,
`docs/perf-results/clone-scan-ab.txt`); adding PRIVATESIZE made it ~1.9×. The
plan's budget for a default was +10% at p95. The kernel does the extra work
per file, so there is no cheaper way to ask; a second pass would cost a whole
walk.
Overview says plainly that clones are counted per copy when it is off, and
links to Settings.

### Staging from the scan tree: exact, or a walk (2026-10-03)

The cleanup queue's reclaim figure promises what emptying the Trash frees,
so a figure from the tree is used only when it equals the walk's
(`StorageSharing.seededMeasurement`, checked by `Profile ==` in tests and on
real folders): the folder is in the tree, FSEvents (after a barrier) reports
nothing under it since the scan's start id, and on APFS the scan read every
sharing fact (`.full`). Anything else walks, as before, and the reason is
logged. Rejected: using a `.refcount` tree — an edited clone looks plain
there, and its shared blocks would count as freed (an overestimate);
parallelising the walk instead (ruled out earlier). Accepted window: a file
here cloned or hard-linked *from another folder* after the scan raises no
event here — the same window every scan-based number has.

### Storage history: folder sizes, not trees (2026-10-03)

"What grew this week" needs last week's sizes, not last week's tree. Each
scan appends a few hundred root-relative folder sizes (~15 KB) to one JSON
file per scanned root; retention keeps ~80 entries (a day each for a month, a
week each for a year). Rejected: keeping snapshots for this (hundreds of MB a
week) and diffing trees (Snapshot compare already does that, on request).
Entries remember the clone accounting they were counted with and are compared
only with entries counted the same way. The file is written with
`Data.write(.atomic)` and never removed; a damaged one is left in place and a
`.v2.json` beside it is used instead.

### Put Back moves out of the Trash, never over anything (2026-10-03)

`CleanupQueue.putBack` is the second place DiskMap moves user files, and the
only one that is not `trashItem`. It is a move *into* the user's folders, not
a removal: each item from the last cleanup goes back only when it is still in
the Trash and its original path is free (checked with `lstat`, so even a
dangling symlink counts as occupied); otherwise it is skipped with the reason
("Already removed from the Trash", "Something new is at …"). A missing parent
folder is recreated. The record (original path, Trash path, bytes) comes from
`trashItem`'s `resultingItemURL`, is kept in
`~/Library/Application Support/DiskMap/last-cleanup.json` so Put Back works
after a relaunch, and is replaced (atomically, by an empty record) once used.
Only items moved by themselves are recorded; a child that went with its
folder comes back with the folder. Rule 1 in AGENTS.md is unchanged: nothing
is removed except through `CleanupQueue.commit()` → Trash.

### Rejected: reserving tree capacity from the last scan (2026-10-03)

Reserving the arrays and intern table for the last scan's size (× 1.1) was
measured in alternating pairs against the fixed 1M/400k reservation and was
no faster (paired median 1.07×). Amortised regrowth of a few hundred MB costs
tens of milliseconds in a ~16 s walk; the walk's tail came from other load on
the machine. Kept simple: the fixed reservation stays.

### Visual regression: one fixture, one machine for baselines (2026-10-03)

`scripts/render-all.sh` renders every screen from a fixed fixture with the
harness in `--deterministic` mode (fixed volume figures, a plain model with no
cache or history, default settings, no timing text) and `ImageDiff` compares
with `docs/visual-baseline` (tolerance 8/255 per channel, fail above 0.5% of
pixels). Two local runs matched (91 identical, one at 0.035%). Baselines are
produced on CI because fonts, file icons and antialiasing differ between
Macs; a laptop's renders are compared only with themselves. Screens that list
the machine's own state (Applications, Snapshots) are left out.

### Updates: Sparkle, opt-in, in one file (2026-10-03)

The maintainer chose Sparkle with automatic checks off by default — the one
exception to "nothing calls the network" (AGENTS.md rule 2, amended). All of
it is in `Updates.swift`: the updater is not created at launch unless the user
turned automatic checks on; "Check for Updates…" is the only other way in; a
build without `SUFeedURL` and `SUPublicEDKey` cannot check at all and says so.
`NetworkPolicyTests` keeps networking APIs and `import Sparkle` out of every
other source file. Rejected: a home-grown version check (still networking,
without signature verification) and auto-checks on by default (breaks the
offline promise for everyone to save some a click).
