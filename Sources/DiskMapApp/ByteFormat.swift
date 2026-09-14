import Foundation

/// Single shared size formatter for the whole UI.
enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

func diskByteString(_ bytes: Int64) -> String {
    ByteFormat.string(bytes)
}
