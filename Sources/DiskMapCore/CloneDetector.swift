import Darwin

/// Detects APFS clones by comparing physical extent maps via `fcntl`,
/// instead of hashing file content. A clone (`cp -c`, `clonefile()`,
/// Finder's "Duplicate") has a different inode but shares the original's
/// extents until a write copy-on-writes that range.
///
/// Verified against the Command Line Tools macOS 15.5 SDK
/// (`xcrun --show-sdk-path` → `MacOSX.sdk/usr/include/sys/fcntl.h`),
/// 2026-09-13:
/// - `F_LOG2PHYS` is 49. `F_LOG2PHYS_EXT` is 65.
/// - `struct log2phys` is `#pragma pack(4)`: `l2p_flags` at 0 (`unsigned
///   int`), `l2p_contigbytes` at 4 (`off_t`), `l2p_devoffset` at 12
///   (`off_t`). Size 20, alignment 4. This file uses the SDK struct
///   imported by Darwin. A hand-rolled Swift struct of the same three
///   fields is 24 bytes (`off_t` aligned to 8, so `devoffset` is read at
///   16 instead of 12). On a real pair of unrelated 8192-byte files that
///   misread reported 92 for both, while the packed struct reported
///   397016842240 vs 397018812416.
/// - `F_LOG2PHYS` only maps the current file offset and does not fill
///   `l2p_contigbytes` ("not yet implemented" in the header). A fresh
///   sequential file of 4 KB, 64 KB, 1 MB, and 8 MB was a single extent,
///   so first-offset comparison happens to match a `cp -c` of those
///   files. It is not enough: after a 4 KB write at offset 1 MB of an
///   8 MB clone, `F_LOG2PHYS` still returned the original's device
///   offset (439726190592) while `F_LOG2PHYS_EXT` showed three extents
///   and a different middle range. First-extent-only would skip hashing
///   a file that is no longer a byte copy. Extent maps are compared
///   instead.
public enum CloneDetector {

    private struct Extent: Equatable {
        var fileOffset: off_t
        var deviceOffset: off_t
        var contigBytes: off_t
    }

    /// Full physical map, or nil if the file can't be mapped (missing,
    /// empty, not a filesystem that answers `F_LOG2PHYS_EXT`).
    private static func extentMap(of path: String) -> [Extent]? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > 0 else { return nil }

        var fileOffset: off_t = 0
        var extents: [Extent] = []
        while fileOffset < info.st_size {
            var query = log2phys()
            query.l2p_devoffset = fileOffset
            query.l2p_contigbytes = info.st_size - fileOffset
            guard fcntl(fd, F_LOG2PHYS_EXT, &query) == 0, query.l2p_contigbytes > 0 else {
                return nil
            }
            extents.append(Extent(
                fileOffset: fileOffset,
                deviceOffset: query.l2p_devoffset,
                contigBytes: query.l2p_contigbytes
            ))
            let next = fileOffset + query.l2p_contigbytes
            if next <= fileOffset || extents.count > 4096 { return nil }
            fileOffset = next
        }
        return fileOffset == info.st_size ? extents : nil
    }

    /// True only when both files share the same physical extents across
    /// their whole length. A first-block match is not enough: a clone
    /// overwritten in the middle still shares the head extent and is not
    /// a duplicate.
    public static func areLikelyClones(_ pathA: String, _ pathB: String) -> Bool {
        guard pathA != pathB,
              let mapA = extentMap(of: pathA),
              let mapB = extentMap(of: pathB) else {
            return false
        }
        return mapA == mapB
    }
}
