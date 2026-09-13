import Foundation

/// A compact, cache-friendly representation of a scanned filesystem tree.
///
/// This is the single biggest lever on scan memory. A naive Swift scanner
/// that allocates one `class FileNode` per file pays ~48+ bytes of
/// object/ARC overhead *before* storing a single byte of real data, plus
/// every String field is its own heap allocation. Multiply by a few
/// million files and you're well into gigabytes for metadata that should
/// fit in tens of megabytes — this is almost certainly the exact bug
/// DiskBuddy's "3.2 GB -> 18 MB" changelog line describes fixing.
///
/// The fix is a struct-of-arrays layout: every field lives in its own
/// packed array, nodes are referenced by Int32 index instead of pointer,
/// and repeated strings (folder names like "node_modules", "Library",
/// ".git") are interned once instead of re-allocated per occurrence.
public struct FileTree: Sendable {

    // MARK: Name interning

    public private(set) var nameTable: [String] = []
    private var nameLookup: [String: Int32] = [:]
    /// Open-addressed intern table for the scan hot path. A hit compares
    /// raw UTF-8 and does not allocate a `String`. Empty slots use `-1`.
    private var internSlotHash: [UInt64] = []
    private var internSlotIndex: [Int32] = []
    private var internCount = 0

    // MARK: Struct-of-arrays node storage, indexed by node id (Int32)

    public private(set) var nameIndex: [Int32] = []
    public private(set) var parent: [Int32] = []        // -1 for root
    public private(set) var firstChild: [Int32] = []    // -1 if none
    public private(set) var nextSibling: [Int32] = []   // -1 if none
    public private(set) var logicalSize: [Int64] = []   // st_size
    public private(set) var allocatedSize: [Int64] = [] // size-on-disk (reflects APFS compression)
    public private(set) var modifiedDay: [Int32] = []   // days since epoch, not a full Date (8 bytes -> 4)
    public private(set) var isDirectory: [Bool] = []
    public private(set) var flags: [UInt8] = []         // see NodeFlags

    public var count: Int { nameIndex.count }

    /// Bytes per node of the packed arrays only: index, parent links,
    /// sizes, day, directory bit, flags. No spare capacity, no interned
    /// string heap. Built from `MemoryLayout` so the number tracks the
    /// stored types instead of a handwritten guess.
    public static var packedNodeStride: Int {
        MemoryLayout<Int32>.stride * 5
            + MemoryLayout<Int64>.stride * 2
            + MemoryLayout<Bool>.stride
            + MemoryLayout<UInt8>.stride
    }

    /// Packed-array bytes if every array's count equals `nodeCount` and
    /// there is no spare capacity. Name strings are not included.
    public static func packedNodeBytesExact(nodeCount: Int) -> Int {
        nodeCount * packedNodeStride
    }

    public struct StorageFootprint: Sendable, Equatable {
        public var nodeCount: Int
        public var uniqueNameCount: Int
        /// `MemoryLayout` × node count. Minimum the packed arrays can be.
        public var packedNodeBytesExact: Int
        /// `MemoryLayout` × each array's current capacity. What is reserved now.
        public var packedNodeBytesReserved: Int
        /// `MemoryLayout<String>` × unique names. The string headers, not the characters.
        public var nameTableHeaderBytes: Int
        /// Sum of UTF-8 byte counts of interned names. Measured, not a layout formula.
        public var nameUTF8Bytes: Int
    }

    public func storageFootprint() -> StorageFootprint {
        let reserved = nameIndex.capacity * MemoryLayout<Int32>.stride
            + parent.capacity * MemoryLayout<Int32>.stride
            + firstChild.capacity * MemoryLayout<Int32>.stride
            + nextSibling.capacity * MemoryLayout<Int32>.stride
            + modifiedDay.capacity * MemoryLayout<Int32>.stride
            + logicalSize.capacity * MemoryLayout<Int64>.stride
            + allocatedSize.capacity * MemoryLayout<Int64>.stride
            + isDirectory.capacity * MemoryLayout<Bool>.stride
            + flags.capacity * MemoryLayout<UInt8>.stride
        let utf8 = nameTable.reduce(0) { $0 + $1.utf8.count }
        return StorageFootprint(
            nodeCount: count,
            uniqueNameCount: nameTable.count,
            packedNodeBytesExact: Self.packedNodeBytesExact(nodeCount: count),
            packedNodeBytesReserved: reserved,
            nameTableHeaderBytes: nameTable.count * MemoryLayout<String>.stride,
            nameUTF8Bytes: utf8
        )
    }

    /// Drop amortized-doubling slack so each packed array is copied into a
    /// buffer sized for its count. Swift's `Array.capacity` is a minimum
    /// the allocator may round up, so reserved bytes can sit a little above
    /// the exact `MemoryLayout` total — that rounding is not the ~2× spare
    /// capacity `append` leaves behind. Call once after a scan, not during
    /// inserts — `addNode` stays O(1) amortized.
    public mutating func compact() {
        nameIndex = Self.exactCopy(nameIndex)
        parent = Self.exactCopy(parent)
        firstChild = Self.exactCopy(firstChild)
        nextSibling = Self.exactCopy(nextSibling)
        logicalSize = Self.exactCopy(logicalSize)
        allocatedSize = Self.exactCopy(allocatedSize)
        modifiedDay = Self.exactCopy(modifiedDay)
        isDirectory = Self.exactCopy(isDirectory)
        flags = Self.exactCopy(flags)
        nameTable = Self.exactCopy(nameTable)
    }

    private static func exactCopy<T>(_ source: [T]) -> [T] {
        source.withUnsafeBufferPointer { buffer in
            Array(unsafeUninitializedCapacity: buffer.count) { destination, initializedCount in
                if let base = buffer.baseAddress, buffer.count > 0 {
                    destination.baseAddress?.initialize(from: base, count: buffer.count)
                }
                initializedCount = buffer.count
            }
        }
    }

    @discardableResult
    public mutating func addNode(
        name: String,
        parent parentID: Int32,
        isDirectory: Bool,
        logicalSize: Int64,
        allocatedSize: Int64,
        modifiedDaysSinceEpoch: Int32,
        flags: UInt8 = 0
    ) -> Int32 {
        appendNode(
            nameID: internName(name),
            parent: parentID,
            isDirectory: isDirectory,
            logicalSize: logicalSize,
            allocatedSize: allocatedSize,
            modifiedDaysSinceEpoch: modifiedDaysSinceEpoch,
            flags: flags
        )
    }

    /// Same as `addNode(name:)` but the name is raw UTF-8 from
    /// `getattrlistbulk`, without a `String` allocation on a hit.
    @discardableResult
    mutating func addNode(
        utf8 nameBytes: UnsafeBufferPointer<UInt8>,
        parent parentID: Int32,
        isDirectory: Bool,
        logicalSize: Int64,
        allocatedSize: Int64,
        modifiedDaysSinceEpoch: Int32,
        flags: UInt8 = 0
    ) -> Int32 {
        let nid = internUTF8(nameBytes)
        return appendNode(
            nameID: nid,
            parent: parentID,
            isDirectory: isDirectory,
            logicalSize: logicalSize,
            allocatedSize: allocatedSize,
            modifiedDaysSinceEpoch: modifiedDaysSinceEpoch,
            flags: flags
        )
    }

    private mutating func appendNode(
        nameID nid: Int32,
        parent parentID: Int32,
        isDirectory: Bool,
        logicalSize: Int64,
        allocatedSize: Int64,
        modifiedDaysSinceEpoch: Int32,
        flags: UInt8
    ) -> Int32 {
        let id = Int32(nameIndex.count)
        nameIndex.append(nid)
        self.parent.append(parentID)
        firstChild.append(-1)
        nextSibling.append(-1)
        self.logicalSize.append(logicalSize)
        self.allocatedSize.append(allocatedSize)
        modifiedDay.append(modifiedDaysSinceEpoch)
        self.isDirectory.append(isDirectory)
        self.flags.append(flags)
        if parentID >= 0 {
            // Prepend to the parent's child list — O(1) insert. Child
            // order doesn't matter for a treemap since layout algorithms
            // re-sort by size anyway.
            let prevHead = firstChild[Int(parentID)]
            nextSibling[Int(id)] = prevHead
            firstChild[Int(parentID)] = id
        }
        return id
    }

    private mutating func internUTF8(_ bytes: UnsafeBufferPointer<UInt8>) -> Int32 {
        if internSlotHash.isEmpty { growIntern(to: 1024) }
        let hash = fnv1a(bytes)
        if let existing = findIntern(hash: hash, bytes: bytes) { return existing }
        if (internCount + 1) * 2 >= internSlotHash.count {
            growIntern(to: internSlotHash.count * 2)
        }
        let name = String(decoding: bytes, as: UTF8.self)
        if let existing = nameLookup[name] { return existing }
        let id = Int32(nameTable.count)
        nameTable.append(name)
        nameLookup[name] = id
        insertIntern(hash: hash, id: id)
        return id
    }

    private func findIntern(hash: UInt64, bytes: UnsafeBufferPointer<UInt8>) -> Int32? {
        guard !internSlotHash.isEmpty else { return nil }
        let mask = internSlotHash.count - 1
        var slot = Int(truncatingIfNeeded: hash) & mask
        var probes = 0
        while internSlotIndex[slot] != -1, probes < internSlotHash.count {
            if internSlotHash[slot] == hash, nameTable[Int(internSlotIndex[slot])].utf8.elementsEqual(bytes) {
                return internSlotIndex[slot]
            }
            slot = (slot + 1) & mask
            probes += 1
        }
        return nil
    }

    private mutating func insertIntern(hash: UInt64, id: Int32) {
        let mask = internSlotHash.count - 1
        var slot = Int(truncatingIfNeeded: hash) & mask
        while internSlotIndex[slot] != -1 {
            slot = (slot + 1) & mask
        }
        internSlotHash[slot] = hash
        internSlotIndex[slot] = id
        internCount += 1
    }

    private mutating func growIntern(to count: Int) {
        let size = max(count, 1024)
        internSlotHash = Array(repeating: 0, count: size)
        internSlotIndex = Array(repeating: -1, count: size)
        internCount = 0
        for (offset, name) in nameTable.enumerated() {
            let hash = name.utf8.withContiguousStorageIfAvailable { fnv1a($0) } ?? fnv1a(Array(name.utf8))
            insertIntern(hash: hash, id: Int32(offset))
        }
    }

    private func fnv1a(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt64 {
        var hash: UInt64 = 14695981039346656037
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return hash == 0 ? 1 : hash
    }

    private func fnv1a(_ bytes: [UInt8]) -> UInt64 {
        bytes.withUnsafeBufferPointer { fnv1a($0) }
    }

    private mutating func internName(_ name: String) -> Int32 {
        if let existing = nameLookup[name] { return existing }
        let idx = Int32(nameTable.count)
        nameTable.append(name)
        nameLookup[name] = idx
        return idx
    }

    public func name(of id: Int32) -> String {
        nameTable[Int(nameIndex[Int(id)])]
    }

    public func flags(of id: Int32) -> UInt8 {
        flags[Int(id)]
    }

    /// Root first, `id` last. Used by the treemap breadcrumb. Stops if a
    /// parent pointer cycles so a corrupt scan can't hang the UI.
    public func ancestorIDs(of id: Int32) -> [Int32] {
        guard id >= 0, id < count else { return [] }
        var chain: [Int32] = []
        var current = id
        var seen = 0
        while current >= 0, seen < count {
            chain.append(current)
            let parentID = parent[Int(current)]
            if parentID == current { break }
            current = parentID
            seen += 1
        }
        return chain.reversed()
    }

    /// Reconstructs the full path of a node by walking parent pointers.
    /// O(depth) — fine for on-demand UI lookups (e.g. "reveal in Finder"),
    /// don't call this in a tight loop over every node.
    public func path(of id: Int32, root: URL) -> URL {
        var components: [String] = []
        var current = id
        while current != 0 {
            components.append(name(of: current))
            current = parent[Int(current)]
        }
        var url = root
        for component in components.reversed() {
            url.appendPathComponent(component)
        }
        return url
    }

    /// Post-order rollup of every node's subtree in `basis`. Call once
    /// after a scan (or a batch of live-updates) rather than maintaining
    /// running totals on every insert, which would make the O(1) insert
    /// above O(depth).
    ///
    /// A normal directory contributes only its children — its own
    /// `fileSize` is directory metadata, not subtree bytes. A
    /// not-downloaded directory is the exception: descendants were not
    /// enumerated, so the cloud size, if the filesystem reported one,
    /// lives on that node.
    public func rollUpSizes(basis: SizeBasis = .allocated) -> [Int64] {
        var totals = [Int64](repeating: 0, count: count)
        guard count > 0 else { return totals }

        func sum(_ id: Int32) -> Int64 {
            var total = ownSize(id, basis: basis)
            var child = firstChild[Int(id)]
            while child != -1 {
                total += sum(child)
                child = nextSibling[Int(child)]
            }
            totals[Int(id)] = total
            return total
        }
        _ = sum(0)
        return totals
    }

    private func ownSize(_ id: Int32, basis: SizeBasis) -> Int64 {
        let index = Int(id)
        let selected = basis == .logical ? logicalSize[index] : allocatedSize[index]
        if !isDirectory[index] { return selected }
        let evictedWithoutChildren = flags[index] & NodeFlags.notDownloaded != 0 && firstChild[index] == -1
        return evictedWithoutChildren ? selected : 0
    }

    /// Replaces packed storage after a snapshot load and rebuilds the
    /// name lookup. Arrays must all have `nameIndex.count` elements.
    /// Returns false and leaves the tree unchanged if the counts disagree.
    public mutating func replacePacked(
        nameTable: [String],
        nameIndex: [Int32],
        parent: [Int32],
        firstChild: [Int32],
        nextSibling: [Int32],
        logicalSize: [Int64],
        allocatedSize: [Int64],
        modifiedDay: [Int32],
        isDirectory: [Bool],
        flags: [UInt8]
    ) -> Bool {
        let n = nameIndex.count
        guard parent.count == n, firstChild.count == n, nextSibling.count == n,
              logicalSize.count == n, allocatedSize.count == n, modifiedDay.count == n,
              isDirectory.count == n, flags.count == n else { return false }
        for index in nameIndex where index < 0 || index >= nameTable.count { return false }
        self.nameTable = nameTable
        var lookup: [String: Int32] = [:]
        lookup.reserveCapacity(nameTable.count)
        for (offset, name) in nameTable.enumerated() {
            if lookup[name] == nil { lookup[name] = Int32(offset) }
        }
        nameLookup = lookup
        internSlotHash = []
        internSlotIndex = []
        internCount = 0
        self.nameIndex = nameIndex
        self.parent = parent
        self.firstChild = firstChild
        self.nextSibling = nextSibling
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.modifiedDay = modifiedDay
        self.isDirectory = isDirectory
        self.flags = flags
        return true
    }

    /// Convenience for building treemap input at any node: direct
    /// children with their rolled-up sizes.
    public func children(of id: Int32, totals: [Int64]) -> [(id: Int32, size: Int64)] {
        var result: [(id: Int32, size: Int64)] = []
        var child = firstChild[Int(id)]
        while child != -1 {
            result.append((id: child, size: totals[Int(child)]))
            child = nextSibling[Int(child)]
        }
        return result
    }
}
