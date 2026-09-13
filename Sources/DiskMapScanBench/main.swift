import DiskMapCore
import Foundation

let path = CommandLine.arguments.dropFirst().first ?? NSHomeDirectory()
let root = URL(fileURLWithPath: path, isDirectory: true)
let engine = ScanEngine()
let result = await engine.scan(root: root)
let foot = result.tree.storageFootprint()
print(
  "bench tree_nodes=\(result.tree.count) unique_names=\(foot.uniqueNameCount) name_utf8=\(foot.nameUTF8Bytes) packed_exact=\(foot.packedNodeBytesExact) packed_reserved=\(foot.packedNodeBytesReserved)"
)
