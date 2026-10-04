import Foundation

/// TASK-036 evidence tool. Measures the real `getattrlistbulk` record layout
/// for the extended attribute mask (DEVID + FILEID + LINKCOUNT) instead of
/// hand-deriving offsets from the header.
///
/// Method: build a fixture whose `lstat` values are known and distinctive,
/// ask the kernel for one page of records, then search each record for those
/// exact values. An offset is only reported when the bytes there match ground
/// truth, so the output is evidence, not a guess.
///
/// Run: swift run AttrProbe
/// Record the output in docs/perf-results/attr-probe.txt and cite it in the
/// BulkScan.parse() header comment.

// MARK: - Attribute constants (verified against the active SDK's sys/attr.h)

let ATTR_CMN_RETURNED_ATTRS_: UInt32 = 0x8000_0000
let ATTR_CMN_NAME_: UInt32           = 0x0000_0001
let ATTR_CMN_DEVID_: UInt32          = 0x0000_0002
let ATTR_CMN_OBJTYPE_: UInt32        = 0x0000_0008
let ATTR_CMN_CRTIME_: UInt32         = 0x0000_0200
let ATTR_CMN_MODTIME_: UInt32        = 0x0000_0400
let ATTR_CMN_FLAGS_: UInt32          = 0x0004_0000
let ATTR_CMN_FILEID_: UInt32         = 0x0200_0000
let ATTR_CMN_ERROR_: UInt32          = 0x2000_0000

let ATTR_DIR_LINKCOUNT_: UInt32      = 0x0000_0001
let ATTR_DIR_ALLOCSIZE_: UInt32      = 0x0000_0008
let ATTR_DIR_DATALENGTH_: UInt32     = 0x0000_0020

let ATTR_FILE_LINKCOUNT_: UInt32     = 0x0000_0001
let ATTR_FILE_TOTALSIZE_: UInt32     = 0x0000_0002
let ATTR_FILE_ALLOCSIZE_: UInt32     = 0x0000_0004

// MARK: - Fixture

let fm = FileManager.default
let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("diskmap-attrprobe-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }

// A file with a deliberately odd size so it cannot collide with a timestamp
// or an inode by accident.
let knownSize = 4_242
let fileURL = root.appendingPathComponent("probe-file.bin")
try Data(repeating: 0xAB, count: knownSize).write(to: fileURL)

// A second name for the same inode, so st_nlink == 2 and the link-count
// field is distinguishable from the overwhelmingly common value 1.
let linkURL = root.appendingPathComponent("probe-file.link")
guard link(fileURL.path, linkURL.path) == 0 else {
    fatalError("link() failed: \(String(cString: strerror(errno)))")
}

let dirURL = root.appendingPathComponent("probe-dir")
try fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
// Give the directory a couple of children so its link count is not 2.
for i in 0..<3 {
    try fm.createDirectory(at: dirURL.appendingPathComponent("sub\(i)"), withIntermediateDirectories: true)
}

struct Truth {
    var name: String
    var ino: UInt64
    var nlink: UInt32
    var size: Int64
    var alloc: Int64
    var dev: Int32
    var mtime: Int64
    var ctime: Int64
    var isDir: Bool
}

func truth(_ url: URL) -> Truth {
    var st = stat()
    guard lstat(url.path, &st) == 0 else {
        fatalError("lstat failed for \(url.path)")
    }
    return Truth(
        name: url.lastPathComponent,
        ino: UInt64(st.st_ino),
        nlink: UInt32(st.st_nlink),
        size: Int64(st.st_size),
        alloc: Int64(st.st_blocks) * 512,
        dev: Int32(st.st_dev),
        mtime: Int64(st.st_mtimespec.tv_sec),
        ctime: Int64(st.st_birthtimespec.tv_sec),
        isDir: (st.st_mode & S_IFMT) == S_IFDIR
    )
}

let truths = [truth(fileURL), truth(dirURL), truth(linkURL)]

print("=== ground truth (lstat) ===")
for t in truths {
    print("""
    \(t.name): isDir=\(t.isDir) ino=\(t.ino) nlink=\(t.nlink) \
    size=\(t.size) alloc=\(t.alloc) dev=\(t.dev) mtime=\(t.mtime) birth=\(t.ctime)
    """)
}
print("")

// MARK: - The call

var list = attrlist()
memset(&list, 0, MemoryLayout<attrlist>.size)
list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
list.commonattr = ATTR_CMN_RETURNED_ATTRS_ | ATTR_CMN_NAME_ | ATTR_CMN_DEVID_
    | ATTR_CMN_ERROR_ | ATTR_CMN_OBJTYPE_ | ATTR_CMN_CRTIME_ | ATTR_CMN_MODTIME_
    | ATTR_CMN_FLAGS_ | ATTR_CMN_FILEID_
list.dirattr = ATTR_DIR_LINKCOUNT_ | ATTR_DIR_ALLOCSIZE_ | ATTR_DIR_DATALENGTH_
list.fileattr = ATTR_FILE_LINKCOUNT_ | ATTR_FILE_TOTALSIZE_ | ATTR_FILE_ALLOCSIZE_

let options = UInt64(FSOPT_NOFOLLOW | FSOPT_PACK_INVAL_ATTRS)

let fd = root.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
guard fd >= 0 else { fatalError("open failed") }
defer { close(fd) }

var buffer = [UInt8](repeating: 0, count: 256 * 1024)

func load<T>(_ type: T.Type, _ buf: [UInt8], _ off: Int) -> T? {
    guard off >= 0, off + MemoryLayout<T>.size <= buf.count else { return nil }
    return buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: type) }
}

/// Every 4-byte-aligned offset in the record where `value` appears as `T`.
func findAll<T: Equatable>(_ value: T, _ type: T.Type, in buf: [UInt8], start: Int, end: Int) -> [Int] {
    var hits: [Int] = []
    var off = start
    while off + MemoryLayout<T>.size <= end {
        if let got = load(type, buf, off), got == value { hits.append(off - start) }
        off += 4
    }
    return hits
}

func hexdump(_ buf: [UInt8], start: Int, count: Int) -> String {
    var out = ""
    var i = 0
    while i < count {
        let lineLen = min(16, count - i)
        let bytes = (0..<lineLen).map { String(format: "%02x", buf[start + i + $0]) }
        out += String(format: "  %04d  ", i) + bytes.joined(separator: " ") + "\n"
        i += lineLen
    }
    return out
}

var recordsSeen = 0
while true {
    let count = buffer.withUnsafeMutableBytes { raw -> Int32 in
        getattrlistbulk(fd, &list, raw.baseAddress, raw.count, options)
    }
    if count <= 0 {
        if count < 0 { print("getattrlistbulk failed: \(String(cString: strerror(errno)))") }
        break
    }

    var offset = 0
    for _ in 0..<Int(count) {
        guard let lengthRaw = load(UInt32.self, buffer, offset) else { break }
        let length = Int(lengthRaw)
        guard length > 0, offset + length <= buffer.count else { break }
        defer { offset += length }
        recordsSeen += 1

        // Identify which fixture this record is by matching the inode, which
        // is the one value guaranteed unique and non-zero here.
        let matched = truths.first { t in
            !findAll(t.ino, UInt64.self, in: buffer, start: offset, end: offset + length).isEmpty
        }
        guard let t = matched else { continue }

        print("=== record for \(t.name) (isDir=\(t.isDir)) — length \(length) ===")
        print(hexdump(buffer, start: offset, count: length))

        func report(_ label: String, _ offs: [Int]) {
            let shown = offs.isEmpty ? "NOT FOUND" : offs.map(String.init).joined(separator: ", ")
            print(String(format: "  %-22s %@", (label as NSString).utf8String!, shown as NSString))
        }
        let s = offset, e = offset + length
        report("FILEID (u64)",    findAll(t.ino, UInt64.self, in: buffer, start: s, end: e))
        report("DEVID (i32)",     findAll(t.dev, Int32.self, in: buffer, start: s, end: e))
        report("LINKCOUNT (u32)", findAll(t.nlink, UInt32.self, in: buffer, start: s, end: e))
        report("size (i64)",      findAll(t.size, Int64.self, in: buffer, start: s, end: e))
        report("alloc (i64)",     findAll(t.alloc, Int64.self, in: buffer, start: s, end: e))
        report("MODTIME.sec",     findAll(t.mtime, Int64.self, in: buffer, start: s, end: e))
        report("CRTIME.sec",      findAll(t.ctime, Int64.self, in: buffer, start: s, end: e))
        print("")
    }
}

print("records examined: \(recordsSeen)")

// MARK: - TASK-077: the scan mask plus APFS extended attributes

/// `swift run AttrProbe --extended`: BulkScan's exact mask, plus
/// forkattr = PRIVATESIZE | CLONEID | EXT_FLAGS | CLONE_REFCNT with
/// FSOPT_ATTR_CMN_EXTENDED, on a fixture holding a pure clone pair and an
/// edited clone. Ground truth for the extended values comes from single-object
/// `getattrlist` at the offsets StorageSharingTests verified against lstat.
if CommandLine.arguments.contains("--extended") {
    let ATTR_CMNEXT_PRIVATESIZE_: UInt32 = 0x0000_0008
    let ATTR_CMNEXT_CLONEID_: UInt32     = 0x0000_0100
    let ATTR_CMNEXT_EXT_FLAGS_: UInt32   = 0x0000_0200
    let ATTR_CMNEXT_CLONE_REFCNT_: UInt32 = 0x0000_1000
    let FSOPT_ATTR_CMN_EXTENDED_: UInt32 = 0x0000_0020
    // `--refcount-only`: CLONEID + CLONE_REFCNT alone (the cheaper request).
    let refcountOnly = CommandLine.arguments.contains("--refcount-only")
    let extMask = refcountOnly
        ? ATTR_CMNEXT_CLONEID_ | ATTR_CMNEXT_CLONE_REFCNT_
        : ATTR_CMNEXT_PRIVATESIZE_ | ATTR_CMNEXT_CLONEID_ | ATTR_CMNEXT_EXT_FLAGS_ | ATTR_CMNEXT_CLONE_REFCNT_
    let truthMask = ATTR_CMNEXT_PRIVATESIZE_ | ATTR_CMNEXT_CLONEID_ | ATTR_CMNEXT_EXT_FLAGS_ | ATTR_CMNEXT_CLONE_REFCNT_

    let extRoot = root.appendingPathComponent("ext")
    try fm.createDirectory(at: extRoot, withIntermediateDirectories: true)
    // 5 × 16 KiB of distinct blocks, so an edit unshares exactly one block.
    var payload = Data()
    for block in 0..<5 { payload.append(Data(repeating: UInt8(0x30 + block), count: 16_384)) }
    let original = extRoot.appendingPathComponent("clone-a.bin")
    try payload.write(to: original)
    let twin = extRoot.appendingPathComponent("clone-b.bin")
    guard clonefile(original.path, twin.path, 0) == 0 else { fatalError("clonefile failed: \(String(cString: strerror(errno)))") }
    let edited = extRoot.appendingPathComponent("clone-edited.bin")
    guard clonefile(original.path, edited.path, 0) == 0 else { fatalError("clonefile failed") }
    let handle = try FileHandle(forWritingTo: edited)
    try handle.seek(toOffset: 16_384)
    try handle.write(contentsOf: Data(repeating: 0xEE, count: 16_384))
    try handle.synchronize()
    try handle.close()
    let extDir = extRoot.appendingPathComponent("a-dir")
    try fm.createDirectory(at: extDir, withIntermediateDirectories: true)

    struct ExtTruth { var name: String; var ino: UInt64; var isDir: Bool; var alloc: Int64; var priv: Int64; var cloneID: UInt64; var refcnt: UInt32; var returned: UInt32 }
    func extTruth(_ url: URL) -> ExtTruth {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { fatalError("lstat") }
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = ATTR_CMN_RETURNED_ATTRS_ | ATTR_CMN_DEVID_ | ATTR_CMN_OBJTYPE_ | ATTR_CMN_FILEID_
        list.fileattr = ATTR_FILE_LINKCOUNT_ | ATTR_FILE_ALLOCSIZE_
        list.forkattr = truthMask   // the verified single-object layout needs all four
        var buf = [UInt8](repeating: 0, count: 256)
        let rc = buf.withUnsafeMutableBytes { getattrlist(url.path, &list, $0.baseAddress, $0.count, UInt32(FSOPT_NOFOLLOW) | UInt32(FSOPT_PACK_INVAL_ATTRS) | FSOPT_ATTR_CMN_EXTENDED_) }
        guard rc == 0 else { fatalError("getattrlist failed") }
        let isDir = (st.st_mode & S_IFMT) == S_IFDIR
        // Single-object layout (StorageSharing.facts, verified by its tests):
        // 52 PRIVATESIZE · 60 CLONEID · 76 CLONE_REFCNT. Directories carry no
        // file section, so their numbers are not looked up here.
        return ExtTruth(name: url.lastPathComponent, ino: UInt64(st.st_ino), isDir: isDir,
                        alloc: Int64(st.st_blocks) * 512,
                        priv: isDir ? -1 : load(Int64.self, buf, 52) ?? -1,
                        cloneID: isDir ? 0 : load(UInt64.self, buf, 60) ?? 0,
                        refcnt: isDir ? 0 : load(UInt32.self, buf, 76) ?? 0,
                        returned: load(UInt32.self, buf, 20) ?? 0)
    }
    let extTruths = [original, twin, edited, extDir].map(extTruth)
    print("\n=== TASK-077 extended: ground truth (getattrlist single object) ===")
    for t in extTruths {
        print("\(t.name): isDir=\(t.isDir) ino=\(t.ino) alloc=\(t.alloc) private=\(t.priv) cloneID=\(t.cloneID) refcnt=\(t.refcnt) returnedExt=0x\(String(t.returned, radix: 16))")
    }

    var extList = attrlist()
    memset(&extList, 0, MemoryLayout<attrlist>.size)
    extList.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    extList.commonattr = list.commonattr
    extList.dirattr = list.dirattr
    extList.fileattr = list.fileattr
    extList.forkattr = extMask
    let extOptions = UInt64(FSOPT_NOFOLLOW | FSOPT_PACK_INVAL_ATTRS) | UInt64(FSOPT_ATTR_CMN_EXTENDED_)
    let efd = extRoot.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
    guard efd >= 0 else { fatalError("open ext") }
    defer { close(efd) }
    print("mask: common=0x\(String(extList.commonattr, radix: 16)) dir=0x\(String(extList.dirattr, radix: 16)) file=0x\(String(extList.fileattr, radix: 16)) fork(ext)=0x\(String(extList.forkattr, radix: 16)) options=0x\(String(extOptions, radix: 16))\n")
    while true {
        let count = buffer.withUnsafeMutableBytes { getattrlistbulk(efd, &extList, $0.baseAddress, $0.count, extOptions) }
        if count <= 0 {
            if count < 0 { print("getattrlistbulk failed: \(String(cString: strerror(errno)))") }
            break
        }
        var offset = 0
        for _ in 0..<Int(count) {
            guard let lengthRaw = load(UInt32.self, buffer, offset) else { break }
            let length = Int(lengthRaw)
            defer { offset += length }
            // FILEID sits at 80 in this mask (measured in the first part). A
            // clone's CLONEID can equal another file's inode, so match there.
            guard let fileID = load(UInt64.self, buffer, offset + 80),
                  let t = extTruths.first(where: { $0.ino == fileID }) else { continue }
            print("=== bulk record for \(t.name) (isDir=\(t.isDir)) — length \(length) ===")
            print(hexdump(buffer, start: offset, count: length))
            let s = offset, e = offset + length
            func report(_ label: String, _ offs: [Int]) {
                print("  \(label.padding(toLength: 24, withPad: " ", startingAt: 0)) \(offs.isEmpty ? "NOT FOUND" : offs.map(String.init).joined(separator: ", "))")
            }
            let returned = (0..<5).compactMap { load(UInt32.self, buffer, s + 4 + $0 * 4) }
            print("  returned_attrs (common, vol, dir, file, fork/ext): \(returned.map { "0x" + String($0, radix: 16) })")
            report("FILEID (u64)", findAll(t.ino, UInt64.self, in: buffer, start: s, end: e))
            report("alloc (i64)", findAll(t.alloc, Int64.self, in: buffer, start: s, end: e))
            if !t.isDir {
                if !refcountOnly { report("PRIVATESIZE (i64)", findAll(t.priv, Int64.self, in: buffer, start: s, end: e)) }
                report("CLONEID (u64)", findAll(t.cloneID, UInt64.self, in: buffer, start: s, end: e))
                report("CLONE_REFCNT (u32)", findAll(t.refcnt, UInt32.self, in: buffer, start: s, end: e))
            }
            print("")
        }
    }
}
