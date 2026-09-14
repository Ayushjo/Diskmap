import Foundation

enum AppDestination: Hashable, Identifiable {
    case overview
    case biggestFiles
    case biggestFolders
    case forgottenFiles
    case duplicates
    case cleanSafe
    case cleanCaches
    case cleanDownloads
    case cleanMedia
    case fileBrowser
    case visualize
    case developerStorage
    case applications
    case snapshots

    var id: String { label }

    var label: String {
        switch self {
        case .overview: return "Overview"
        case .biggestFiles: return "Biggest Files"
        case .biggestFolders: return "Biggest Folders"
        case .forgottenFiles: return "Forgotten Files"
        case .duplicates: return "Duplicates"
        case .cleanSafe: return "Safe to Review"
        case .cleanCaches: return "Caches"
        case .cleanDownloads: return "Old Downloads"
        case .cleanMedia: return "Large Media"
        case .fileBrowser: return "File Browser"
        case .visualize: return "Visualize"
        case .developerStorage: return "Developer Storage"
        case .applications: return "Applications"
        case .snapshots: return "Snapshots"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .biggestFiles: return "doc.fill"
        case .biggestFolders: return "folder.fill"
        case .forgottenFiles: return "clock.arrow.circlepath"
        case .duplicates: return "doc.on.doc"
        case .cleanSafe: return "leaf"
        case .cleanCaches: return "internaldrive"
        case .cleanDownloads: return "arrow.down.circle"
        case .cleanMedia: return "film"
        case .fileBrowser: return "list.bullet.rectangle"
        case .visualize: return "square.grid.3x3"
        case .developerStorage: return "chevron.left.forwardslash.chevron.right"
        case .applications: return "app"
        case .snapshots: return "camera"
        }
    }
}

enum AppNavSection: String, CaseIterable, Identifiable {
    case main = "Main"
    case find = "Find"
    case clean = "Clean"
    case explore = "Explore"
    var id: String { rawValue }

    var items: [AppDestination] {
        switch self {
        case .main: return [.overview]
        case .find: return [.biggestFiles, .biggestFolders, .forgottenFiles, .duplicates]
        case .clean: return [.cleanSafe, .cleanCaches, .cleanDownloads, .cleanMedia]
        case .explore: return [.fileBrowser, .visualize, .developerStorage, .applications, .snapshots]
        }
    }
}
