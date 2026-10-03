import Foundation

public enum FileKind: String, Sendable, Equatable, CaseIterable {
    case video
    case diskImage
    case archive
    case application
    case document
    case database
    case virtualDisk
    case deviceBackup
    case other

    public var title: String {
        switch self {
        case .video: return "Video"
        case .diskImage: return "Disk Image"
        case .archive: return "Archive"
        case .application: return "Application"
        case .document: return "Document"
        case .database: return "Database"
        case .virtualDisk: return "Virtual Disk"
        case .deviceBackup: return "Device Backup"
        case .other: return "Other"
        }
    }

    public var symbolName: String {
        switch self {
        case .video: return "film"
        case .diskImage: return "opticaldisc"
        case .archive: return "doc.zipper"
        case .application: return "app"
        case .document: return "doc.text"
        case .database: return "cylinder.split.1x2"
        case .virtualDisk: return "externaldrive"
        case .deviceBackup: return "iphone"
        case .other: return "doc"
        }
    }

    public static func classify(fileName: String, path: String = "") -> FileKind {
        let n = fileName.lowercased()
        let p = path.lowercased()
        if n.hasSuffix(".mkv") || n.hasSuffix(".mp4") || n.hasSuffix(".mov") || n.hasSuffix(".m4v")
            || n.hasSuffix(".avi") || n.hasSuffix(".webm") {
            return .video
        }
        if n.hasSuffix(".dmg") || n.hasSuffix(".iso") || n.hasSuffix(".pkg") || n.hasSuffix(".img") {
            return .diskImage
        }
        if n.hasSuffix(".raw") || n.hasSuffix(".vmdk") || n.hasSuffix(".vdi") || n.hasSuffix(".qcow2")
            || n.hasSuffix(".sparseimage") || n.hasSuffix(".sparsebundle") {
            return .virtualDisk
        }
        if n.hasSuffix(".zip") || n.hasSuffix(".tar") || n.hasSuffix(".gz") || n.hasSuffix(".tgz")
            || n.hasSuffix(".7z") || n.hasSuffix(".rar") || n.hasSuffix(".bz2") {
            return .archive
        }
        if n.hasSuffix(".app") || p.contains("/applications/") {
            return .application
        }
        if n.hasSuffix(".sqlite") || n.hasSuffix(".db") || n.hasSuffix(".sql") {
            return .database
        }
        if p.contains("mobilebackup") || p.contains("backup") && (n.hasSuffix(".backup") || p.contains("iphone")) {
            return .deviceBackup
        }
        if n.hasSuffix(".pdf") || n.hasSuffix(".doc") || n.hasSuffix(".docx") || n.hasSuffix(".pages")
            || n.hasSuffix(".txt") || n.hasSuffix(".rtf") || n.hasSuffix(".md") {
            return .document
        }
        if n.hasSuffix(".fcpbundle") || p.contains("final cut") {
            return .other
        }
        return .other
    }

    public static func whyLarge(kind: FileKind, name: String) -> String {
        switch kind {
        case .video:
            return "This is a large video file. High-resolution movies and screen recordings often take many gigabytes."
        case .diskImage:
            return "Disk images and installers store a full copy of software or media. Safe to remove after installation if you still have the original download source."
        case .virtualDisk:
            return "Virtual machine or container disks grow with images, layers, and volumes. Prefer the app’s own cleanup (e.g. Docker Desktop) over deleting this file directly."
        case .archive:
            return "Compressed archives can hold projects, backups, or downloads. Confirm you have extracted anything you need before removing."
        case .database:
            return "Application databases hold structured data. Deleting them can corrupt the app’s state."
        case .deviceBackup:
            return "Device backups are large by design. Manage them in Finder or the backup app rather than deleting raw files."
        case .application:
            return "Application bundles include binaries and resources. Uninstall via Launchpad or the vendor’s uninstaller when possible."
        case .document:
            return "A large document or export. Review whether you still need this copy."
        case .other:
            return "This file is large relative to others on your Mac. Inspect its location and owning app before removing it."
        }
    }
}
