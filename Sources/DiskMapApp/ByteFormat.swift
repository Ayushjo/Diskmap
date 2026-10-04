import Foundation

/// Single shared size formatter for the whole UI.
enum ByteFormat {
    /// "0 bytes", never "Zero KB". Formatters are not free to build, and this
    /// runs for every row of every list.
    private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    static func string(_ bytes: Int64) -> String {
        formatter.string(fromByteCount: bytes)
    }
}

func diskByteString(_ bytes: Int64) -> String {
    ByteFormat.string(bytes)
}
