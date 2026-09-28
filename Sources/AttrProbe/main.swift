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
