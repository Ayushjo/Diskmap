import Foundation

/// TASK-038 evidence tool. Measures what APFS actually reports for
/// ATTR_CMNEXT_PRIVATESIZE / CLONEID / CLONE_REFCNT on known fixtures, and
/// whether getattrlistbulk returns them, before any reclaim math relies on the
/// man page's wording. Record the output in docs/perf-results/sharing-probe.txt.
///
/// Run: swift run SharingProbe

let ATTR_CMN_RETURNED_ATTRS_: UInt32 = 0x8000_0000
let ATTR_CMN_NAME_: UInt32 = 0x0000_0001
let ATTR_CMN_FILEID_: UInt32 = 0x0200_0000
let ATTR_FILE_LINKCOUNT_: UInt32 = 0x0000_0001
let ATTR_FILE_ALLOCSIZE_: UInt32 = 0x0000_0004
let ATTR_CMNEXT_PRIVATESIZE_: UInt32 = 0x0000_0008
let ATTR_CMNEXT_CLONEID_: UInt32 = 0x0000_0100
let ATTR_CMNEXT_EXT_FLAGS_: UInt32 = 0x0000_0200
let ATTR_CMNEXT_CLONE_REFCNT_: UInt32 = 0x0000_1000
let ATTR_VOL_INFO_: UInt32 = 0x8000_0000
let ATTR_VOL_CAPABILITIES_: UInt32 = 0x0002_0000
let FSOPT_ATTR_CMN_EXTENDED_: UInt64 = 0x0000_0020
let VOL_CAP_FMT_CLONE_MAPPING_: UInt32 = 0x0400_0000
let EF_MAY_SHARE_BLOCKS_: UInt64 = 0x0000_0001

func load<T>(_ t: T.Type, _ b: [UInt8], _ o: Int) -> T {
    b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: t) }
}

struct Sharing: CustomStringConvertible {
    var returnedFile: UInt32, returnedExt: UInt32
    var fileID: UInt64, linkCount: UInt32, alloc: Int64
    var privateSize: Int64, cloneID: UInt64, extFlags: UInt64, cloneRefcnt: UInt32
    var description: String {
        "fileID=\(fileID) nlink=\(linkCount) alloc=\(alloc) PRIVATE=\(privateSize) "
        + "cloneID=\(cloneID) mayShare=\(extFlags & EF_MAY_SHARE_BLOCKS_ != 0) REFCNT=\(cloneRefcnt) "
        + String(format: "ret[file]=0x%x ret[ext]=0x%x", returnedFile, returnedExt)
    }
}

/// Layout: length, returned_attrs (5 x u32), FILEID u64, then file attrs
/// (LINKCOUNT u32, ALLOCSIZE off_t), then extended common attrs in bit order
/// (PRIVATESIZE, CLONEID, EXT_FLAGS, CLONE_REFCNT). Validated below against
/// lstat for fileID / nlink / alloc before the extended values are trusted.
func sharing(_ path: String) -> Sharing? {
    var list = attrlist()
    list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    list.commonattr = ATTR_CMN_RETURNED_ATTRS_ | ATTR_CMN_FILEID_
    list.fileattr = ATTR_FILE_LINKCOUNT_ | ATTR_FILE_ALLOCSIZE_
    list.forkattr = ATTR_CMNEXT_PRIVATESIZE_ | ATTR_CMNEXT_CLONEID_ | ATTR_CMNEXT_EXT_FLAGS_ | ATTR_CMNEXT_CLONE_REFCNT_
    var buf = [UInt8](repeating: 0, count: 512)
    let opts = UInt64(FSOPT_NOFOLLOW) | FSOPT_ATTR_CMN_EXTENDED_ | UInt64(FSOPT_PACK_INVAL_ATTRS)
    let rc = buf.withUnsafeMutableBytes { getattrlist(path, &list, $0.baseAddress, $0.count, UInt32(opts)) }
    guard rc == 0 else { print("getattrlist failed \(path): \(String(cString: strerror(errno)))"); return nil }
    return Sharing(
        returnedFile: load(UInt32.self, buf, 16), returnedExt: load(UInt32.self, buf, 20),
        fileID: load(UInt64.self, buf, 24), linkCount: load(UInt32.self, buf, 32),
        alloc: load(Int64.self, buf, 36), privateSize: load(Int64.self, buf, 44),
        cloneID: load(UInt64.self, buf, 52), extFlags: load(UInt64.self, buf, 60),
        cloneRefcnt: load(UInt32.self, buf, 68))
}

func check(_ label: String, _ path: String) {
    var st = stat(); lstat(path, &st)
    guard let s = sharing(path) else { return }
    let ok = s.fileID == UInt64(st.st_ino) && s.linkCount == UInt32(st.st_nlink) && s.alloc == Int64(st.st_blocks) * 512
    print("\(label.padding(toLength: 22, withPad: " ", startingAt: 0)) \(s)  layout_vs_lstat=\(ok ? "OK" : "MISMATCH")")
}

func flush(_ p: String) { let fd = open(p, O_RDONLY); fsync(fd); close(fd) }
func cloneFile(_ a: String, _ b: String) {
    let cp = Process(); cp.executableURL = URL(fileURLWithPath: "/bin/cp"); cp.arguments = ["-c", a, b]
    try? cp.run(); cp.waitUntilExit()
}

let dir = NSTemporaryDirectory() + "diskmap-sharingprobe-\(UUID().uuidString)"
try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(atPath: dir) }
let mb = 1_048_576

// Volume capability.
do {
    var list = attrlist()
    list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    list.volattr = ATTR_VOL_INFO_ | ATTR_VOL_CAPABILITIES_
    var buf = [UInt8](repeating: 0, count: 256)
    let rc = buf.withUnsafeMutableBytes { getattrlist(dir, &list, $0.baseAddress, $0.count, 0) }
    // length u32, then vol_capabilities_attr_t { capabilities[4], valid[4] }.
    let fmtCaps = load(UInt32.self, buf, 4), fmtValid = load(UInt32.self, buf, 20)
    print("volume rc=\(rc) VOL_CAP_FMT_CLONE_MAPPING supported=\(fmtCaps & VOL_CAP_FMT_CLONE_MAPPING_ != 0) valid=\(fmtValid & VOL_CAP_FMT_CLONE_MAPPING_ != 0)")
}

let plain = dir + "/plain.bin"
FileManager.default.createFile(atPath: plain, contents: Data(repeating: 1, count: mb)); flush(plain)

let famA = dir + "/family-a.bin"
FileManager.default.createFile(atPath: famA, contents: Data(repeating: 2, count: mb)); flush(famA)
let famB = dir + "/family-b.bin", famC = dir + "/family-c.bin"
cloneFile(famA, famB); cloneFile(famA, famC)

let pairA = dir + "/pair-a.bin", pairB = dir + "/pair-b.bin"
FileManager.default.createFile(atPath: pairA, contents: Data(repeating: 3, count: mb)); flush(pairA)
cloneFile(pairA, pairB)

let editedSrc = dir + "/edited-src.bin", edited = dir + "/edited-clone.bin"
FileManager.default.createFile(atPath: editedSrc, contents: Data(repeating: 4, count: mb)); flush(editedSrc)
cloneFile(editedSrc, edited)
if let h = FileHandle(forWritingAtPath: edited) {
    try h.seek(toOffset: UInt64(mb / 2)); try h.write(contentsOf: Data(repeating: 9, count: 65_536)); try h.synchronize(); try h.close()
}

let h1 = dir + "/hard-1.bin", h2 = dir + "/hard-2.bin"
FileManager.default.createFile(atPath: h1, contents: Data(repeating: 5, count: mb)); flush(h1)
_ = link(h1, h2)

print("=== getattrlist, FSOPT_ATTR_CMN_EXTENDED (1 MiB files) ===")
check("plain", plain)
check("family-a (3 clones)", famA); check("family-b", famB); check("family-c", famC)
check("pair-a (2 clones)", pairA); check("pair-b", pairB)
check("edited-src", editedSrc); check("edited-clone(+64K)", edited)
check("hard-1", h1); check("hard-2", h2)

print("=== after deleting family-c (does REFCNT follow?) ===")
unlink(famC)
check("family-a", famA); check("family-b", famB)

print("=== getattrlistbulk with FSOPT_ATTR_CMN_EXTENDED ===")
do {
    let fd = open(dir, O_RDONLY | O_DIRECTORY)
    defer { close(fd) }
    var list = attrlist()
    list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    list.commonattr = ATTR_CMN_RETURNED_ATTRS_ | ATTR_CMN_NAME_ | ATTR_CMN_FILEID_
    list.fileattr = ATTR_FILE_LINKCOUNT_ | ATTR_FILE_ALLOCSIZE_
    list.forkattr = ATTR_CMNEXT_PRIVATESIZE_ | ATTR_CMNEXT_CLONEID_ | ATTR_CMNEXT_EXT_FLAGS_ | ATTR_CMNEXT_CLONE_REFCNT_
    var buf = [UInt8](repeating: 0, count: 64 * 1024)
    let opts = FSOPT_ATTR_CMN_EXTENDED_ | UInt64(FSOPT_PACK_INVAL_ATTRS)
    let n = buf.withUnsafeMutableBytes { getattrlistbulk(fd, &list, $0.baseAddress, $0.count, opts) }
    print("bulk entries=\(n) errno=\(n < 0 ? String(cString: strerror(errno)) : "-")")
    var off = 0
    for _ in 0..<max(0, Int(n)) {
        let len = Int(load(UInt32.self, buf, off))
        // length, returned(20), NAME attrref (8) @24, FILEID @32, LINKCOUNT @40,
        // ALLOCSIZE @44, PRIVATESIZE @52, CLONEID @60, EXT_FLAGS @68, REFCNT @76.
        let nameOff = Int(load(Int32.self, buf, off + 24)), nameLen = Int(load(UInt32.self, buf, off + 28))
        let name = String(decoding: buf[(off + 24 + nameOff)..<(off + 24 + nameOff + nameLen - 1)], as: UTF8.self)
        var st = stat(); lstat(dir + "/" + name, &st)
        let fid = load(UInt64.self, buf, off + 32)
        print("  \(name.padding(toLength: 20, withPad: " ", startingAt: 0)) retExt=0x\(String(load(UInt32.self, buf, off + 20), radix: 16)) "
              + "PRIVATE=\(load(Int64.self, buf, off + 52)) cloneID=\(load(UInt64.self, buf, off + 60)) "
              + "REFCNT=\(load(UInt32.self, buf, off + 76)) fileID_ok=\(fid == UInt64(st.st_ino)) alloc_ok=\(load(Int64.self, buf, off + 44) == Int64(st.st_blocks) * 512)")
        off += len
    }
}
