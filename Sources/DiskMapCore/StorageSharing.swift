import Foundation

/// What deleting a set of paths would actually free, from APFS's own per-file
/// accounting instead of apparent size (TASK-038).
///
/// Semantics MEASURED by the `SharingProbe` target on real fixtures
/// (docs/perf-results/sharing-probe.txt, 2026-09-28) — not taken from the man
/// page's wording:
/// - `ATTR_CMNEXT_PRIVATESIZE` is what deleting that one file frees right now:
///   full size for a plain file, 0 for a pure clone, only the diverged bytes
///   for a partially edited clone. It IGNORES hard links: both names of a
///   two-link inode report the full size, so link count still decides.
/// - Pure clones share `ATTR_CMNEXT_CLONEID`, and `ATTR_CMNEXT_CLONE_REFCNT`
///   is the family size including the file itself (3 for three clones; it
///   drops to 2 when one is deleted).
/// - A partially edited clone LEAVES its family (new clone id, refcount 1), so
///   the blocks it still shares are invisible here. Those bytes are reported
///   as unattributed and make the total a lower bound instead of a guess.
/// - Neither the volume capability nor the returned-attributes bitmap can be
///   trusted on its own. `VOL_CAP_FMT_CLONE_MAPPING` read FALSE on an APFS
///   volume whose refcounts were correct, and an FSKit-mounted ExFAT volume
///   set the "returned" bits for all four extended attributes (0x1308) and
///   then returned ZEROS — PRIVATESIZE 0 for an ordinary unshared file, which
///   would have reported "frees nothing" for everything on an external drive.
///   So the extended attributes are used only when the volume's
///   `f_fstypename` is "apfs" AND the bitmap says they came back; otherwise
///   allocated size is used and only hard links are grouped.
/// - A missing refcount is treated as "copies may exist elsewhere", which
///   frees nothing: the conservative direction.
public enum StorageSharing {

    struct InodeKey: Hashable, Sendable {
        var device: Int32
        var inode: UInt64
    }

    struct CloneKey: Hashable, Sendable {
        var device: Int32
        var cloneID: UInt64
    }

    /// One file's facts, as the filesystem reports them.
    struct FileFacts: Equatable, Sendable {
        var device: Int32
        var inode: UInt64
        var isDirectory: Bool
        var linkCount: Int
        var allocated: Int64
        /// nil when the volume did not return PRIVATESIZE.
        var privateSize: Int64?
        var cloneID: UInt64?
        /// nil when the volume did not return CLONE_REFCNT.
        var cloneRefcount: Int?
    }

    struct HardLinkShare: Equatable, Sendable {
        var linkCount: Int
        var bytes: Int64
        var namesStaged: Int
    }

    struct CloneShare: Equatable, Sendable {
        var familySize: Int
        var sharedBytes: Int64
        var membersStaged: Int
    }

    /// Everything reclaim math needs to know about one staged path, kept
    /// compact: ordinary files collapse into sums; only hard-linked and cloned
    /// files are remembered individually, and those are rare.
    public struct Profile: Equatable, Sendable {
        public internal(set) var fileCount = 0
        /// What the path occupies on disk, shared or not.
        public internal(set) var allocatedBytes: Int64 = 0
        /// Freed by deleting this path, excluding hard-linked and cloned data,
        /// which the group rules below decide across the whole queue.
        var ownedBytes: Int64 = 0
        /// Blocks shared with something unidentifiable: partially edited
        /// clones, or data a local snapshot still holds. Real, but whether
        /// deleting frees them cannot be known, so they are not counted.
        public internal(set) var sharedUnattributedBytes: Int64 = 0
        var hardLinks: [InodeKey: HardLinkShare] = [:]
        var clones: [CloneKey: CloneShare] = [:]
        /// False when part of a directory could not be read, or another
        /// volume is mounted inside it.
        public internal(set) var isComplete = true
        /// True when the volume answered PRIVATESIZE for at least one file.
        public internal(set) var usesFilesystemAccounting = false

        mutating func add(_ facts: FileFacts) {
            guard !facts.isDirectory else { return }
            fileCount += 1
            allocatedBytes += facts.allocated
            if facts.privateSize != nil { usesFilesystemAccounting = true }
            let privateBytes = min(facts.privateSize ?? facts.allocated, facts.allocated)

            if facts.linkCount > 1 {
                // PRIVATESIZE ignores link count, so a name is only worth
                // anything once every name of the inode is going.
                let key = InodeKey(device: facts.device, inode: facts.inode)
                var share = hardLinks[key]
                    ?? HardLinkShare(linkCount: facts.linkCount, bytes: privateBytes, namesStaged: 0)
                share.namesStaged += 1
                hardLinks[key] = share
                return
            }

            ownedBytes += privateBytes
            let shared = max(0, facts.allocated - privateBytes)
            guard shared > 0 else { return }
            if let cloneID = facts.cloneID, let refcount = facts.cloneRefcount, refcount > 1 {
                let key = CloneKey(device: facts.device, cloneID: cloneID)
                var share = clones[key] ?? CloneShare(familySize: refcount, sharedBytes: shared, membersStaged: 0)
                share.membersStaged += 1
                share.familySize = max(share.familySize, refcount)
                share.sharedBytes = max(share.sharedBytes, shared)
                clones[key] = share
            } else {
                sharedUnattributedBytes += shared
            }
        }
    }

    /// Profiles a file or a whole directory tree. Returns nil when the path
    /// cannot be examined at all (missing, permission denied), so callers can
    /// fall back to the size they were given.
    ///
    /// Blocks for the duration of a directory walk — call it off Swift's
    /// cooperative pool (see `profileOffPool`).
    public static func profile(atPath path: String) -> Profile? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        var profile = Profile()
        let trustExtended = isAPFS(path)
        if (info.st_mode & S_IFMT) == S_IFDIR {
            walk(directory: path, rootDevice: Int32(info.st_dev), trustExtended: trustExtended, into: &profile)
        } else if let facts = facts(atPath: path, trustExtended: trustExtended) {
            profile.add(facts)
        } else {
            return nil
        }
        return profile
    }

    /// `profile(atPath:)` on a dedicated thread, so a large staged folder
    /// never parks a Swift-concurrency thread (the TASK-066 lesson).
    public static func profileOffPool(atPath path: String) async -> Profile? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Profile?, Never>) in
            BulkScan.startScanThread(name: "DiskMap.cleanup.profile") {
                continuation.resume(returning: profile(atPath: path))
            }
        }
    }

    // MARK: - Reading the filesystem

    /// Single-object record for `getattrlist`:
    ///   0 length · 4 returned_attrs (5 × u32) · 24 DEVID · 28 OBJTYPE ·
    ///   32 FILEID (u64) · 40 LINKCOUNT · 44 ALLOCSIZE (off_t) ·
    ///   52 PRIVATESIZE (off_t) · 60 CLONEID · 68 EXT_FLAGS · 76 CLONE_REFCNT
    /// Verified field-by-field against `lstat` by `StorageSharingTests`.
    static func facts(atPath path: String, trustExtended: Bool? = nil) -> FileFacts? {
        let trustExtended = trustExtended ?? isAPFS(path)
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrReturned | attrDevID | attrObjType | attrFileID
        list.fileattr = attrFileLinkCount | attrFileAlloc
        list.forkattr = extendedMask
        var buffer = [UInt8](repeating: 0, count: 256)
        let options = UInt32(FSOPT_NOFOLLOW) | UInt32(FSOPT_PACK_INVAL_ATTRS) | fsoptCommonExtended
        let rc = buffer.withUnsafeMutableBytes { raw in
            getattrlist(path, &list, raw.baseAddress, raw.count, options)
        }
        guard rc == 0, load(UInt32.self, buffer, 0) >= 80 else { return nil }
        let returnedExt = trustExtended ? load(UInt32.self, buffer, 20) : 0
        return decode(buffer, base: 0, returnedExt: returnedExt, fieldsAt: 24)
    }

    /// Bulk record, one per directory entry. Common prefix:
    ///   0 length · 4 returned_attrs · 24 ERROR · 28 NAME ref (i32 offset,
    ///   u32 length) · 36 DEVID · 40 OBJTYPE · 44 FILEID.
    /// Files then carry 52 LINKCOUNT · 56 ALLOCSIZE · 64 PRIVATESIZE ·
    /// 72 CLONEID · 80 EXT_FLAGS · 88 CLONE_REFCNT · 92 end.
    /// Directories do NOT: measured 2026-09-28, a directory entry omits the
    /// file attributes entirely even with FSOPT_PACK_INVAL_ATTRS (its fixed
    /// part ends at 80, with the extended attributes packed straight after
    /// FILEID). An earlier version assumed zero-filling, rejected every
    /// directory record as too short, and silently lost whole batches. So:
    /// read OBJTYPE first, and only read file fields from file records.
    private static func walk(directory: String, rootDevice: Int32, trustExtended: Bool, into profile: inout Profile) {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrReturned | attrError | attrName | attrDevID | attrObjType | attrFileID
        list.fileattr = attrFileLinkCount | attrFileAlloc
        list.forkattr = extendedMask
        let options = UInt64(FSOPT_PACK_INVAL_ATTRS) | UInt64(fsoptCommonExtended)

        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        var pending = [directory]
        while let current = pending.popLast() {
            let fd = open(current, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else {
                profile.isComplete = false
                continue
            }
            defer { close(fd) }
            while true {
                let count = buffer.withUnsafeMutableBytes { raw in
                    getattrlistbulk(fd, &list, raw.baseAddress, raw.count, options)
                }
                if count <= 0 {
                    if count < 0 { profile.isComplete = false }
                    break
                }
                var offset = 0
                for _ in 0..<Int(count) {
                    guard offset + 4 <= buffer.count else { profile.isComplete = false; break }
                    let length = Int(load(UInt32.self, buffer, offset))
                    // A record we cannot even frame means the rest of this
                    // batch is unreadable: say so rather than lose it quietly.
                    guard length >= 44, offset + length <= buffer.count else {
                        profile.isComplete = false
                        break
                    }
                    defer { offset += length }

                    guard load(UInt32.self, buffer, offset + 24) == 0 else {
                        profile.isComplete = false
                        continue
                    }
                    let isDirectoryEntry = load(UInt32.self, buffer, offset + 40) == vdir
                    let facts: FileFacts
                    if isDirectoryEntry {
                        facts = FileFacts(
                            device: load(Int32.self, buffer, offset + 36), inode: 0, isDirectory: true,
                            linkCount: 1, allocated: 0, privateSize: nil, cloneID: nil, cloneRefcount: nil
                        )
                    } else {
                        guard length >= 92, let decoded = decode(
                            buffer, base: offset,
                            returnedExt: trustExtended ? load(UInt32.self, buffer, offset + 20) : 0,
                            fieldsAt: offset + 36
                        ) else {
                            profile.isComplete = false
                            continue
                        }
                        facts = decoded
                    }

                    if facts.isDirectory {
                        let nameOffset = Int(load(Int32.self, buffer, offset + 28))
                        let nameLength = Int(load(UInt32.self, buffer, offset + 32))
                        let start = offset + 28 + nameOffset
                        guard nameLength > 1, start >= offset, start + nameLength <= offset + length else {
                            profile.isComplete = false
                            continue
                        }
                        let name = String(decoding: buffer[start..<(start + nameLength - 1)], as: UTF8.self)
                        guard name != ".", name != ".." else { continue }
                        if facts.device != rootDevice {
                            // Another volume mounted inside the staged folder:
                            // its bytes are not part of this reclaim.
                            profile.isComplete = false
                            continue
                        }
                        pending.append(current + "/" + name)
                    } else {
                        profile.add(facts)
                    }
                }
            }
        }
    }

    /// Decodes the shared tail of both record kinds, starting at DEVID.
    private static func decode(_ buffer: [UInt8], base: Int, returnedExt: UInt32, fieldsAt start: Int) -> FileFacts? {
        let objType = load(UInt32.self, buffer, start + 4)
        let privateSize = returnedExt & attrExtPrivateSize != 0 ? load(Int64.self, buffer, start + 28) : nil
        let cloneID = returnedExt & attrExtCloneID != 0 ? load(UInt64.self, buffer, start + 36) : nil
        let refcount = returnedExt & attrExtCloneRefcount != 0 ? Int(load(UInt32.self, buffer, start + 52)) : nil
        return FileFacts(
            device: load(Int32.self, buffer, start),
            inode: load(UInt64.self, buffer, start + 8),
            isDirectory: objType == vdir,
            linkCount: Int(load(UInt32.self, buffer, start + 16)),
            allocated: max(0, load(Int64.self, buffer, start + 20)),
            privateSize: privateSize.map { max(0, $0) },
            cloneID: cloneID,
            cloneRefcount: refcount
        )
    }

    /// Only APFS has clones and private-size accounting. Checked by name
    /// because FSKit ExFAT claims to return the extended attributes and fills
    /// them with zeros (see header).
    static func isAPFS(_ path: String) -> Bool {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return false }
        let name = withUnsafeBytes(of: fs.f_fstypename) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return name == "apfs"
    }

    private static func load<T>(_ type: T.Type, _ buffer: [UInt8], _ offset: Int) -> T {
        buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: type) }
    }

    // Values checked against the active SDK's sys/attr.h (2026-09-28).
    private static let attrReturned: UInt32 = 0x8000_0000
    private static let attrError: UInt32 = 0x2000_0000
    private static let attrName: UInt32 = 0x0000_0001
    private static let attrDevID: UInt32 = 0x0000_0002
    private static let attrObjType: UInt32 = 0x0000_0008
    private static let attrFileID: UInt32 = 0x0200_0000
    private static let attrFileLinkCount: UInt32 = 0x0000_0001
    private static let attrFileAlloc: UInt32 = 0x0000_0004
    private static let attrExtPrivateSize: UInt32 = 0x0000_0008
    private static let attrExtCloneID: UInt32 = 0x0000_0100
    private static let attrExtFlags: UInt32 = 0x0000_0200
    private static let attrExtCloneRefcount: UInt32 = 0x0000_1000
    private static let extendedMask = attrExtPrivateSize | attrExtCloneID | attrExtFlags | attrExtCloneRefcount
    private static let fsoptCommonExtended: UInt32 = 0x0000_0020
    private static let vdir: UInt32 = 2
}
