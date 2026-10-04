import Foundation

/// Finds DiskMapCore's bundled JSON (TASK-063 found this broken).
///
/// SwiftPM's generated `Bundle.module` looks only at
/// `<main bundle>/DiskMap_DiskMapCore.bundle` and then at the absolute build
/// path on the machine that compiled it. In a `.app` the resource bundle
/// lives in `Contents/Resources` (codesign rejects anything at the bundle
/// root), so a packaged app silently read its rules from the build folder —
/// blocking on a Downloads-access prompt when launched from Finder, and it
/// would crash on any other Mac. Look in Resources first; `Bundle.module`
/// stays the fallback for `swift run` and tests.
enum DiskMapResources {
    static let bundleName = "DiskMap_DiskMapCore.bundle"

    static let bundle: Bundle? = {
        if let resources = Bundle.main.resourceURL?.appendingPathComponent(bundleName),
           let packaged = Bundle(url: resources) {
            return packaged
        }
        return Bundle.module
    }()

    static func url(forResource name: String, withExtension ext: String) -> URL? {
        bundle?.url(forResource: name, withExtension: ext)
    }
}
