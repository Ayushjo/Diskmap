# Build freedisk.space on macOS

Install Xcode Command Line Tools and confirm `swift --version` works. From this repository:

```bash
swift build
scripts/test.sh
swift run DiskMapApp
```

`DiskMapApp` is the existing SwiftPM target name. The application shown to users is **freedisk.space**.

For a double-clickable local build:

```bash
scripts/build-adhoc.sh
open dist/freedisk.space.app
```

The script builds a release binary, includes the app icon and resources, signs the app ad hoc, and creates `dist/freedisk.space-<version>.dmg`. On first launch, right-click the app and choose **Open** if macOS displays an unidentified-developer warning. Distribution to other Macs without this warning requires Developer ID signing and notarization.

The existing bundle ID defaults to `com.ayushjo.diskmap` to preserve app identity and preferences. `DISKMAP_BUNDLE_ID` can override it for a separate build; changing it for existing users would create a different app identity. Optional Sparkle update checks require a feed URL and public key at packaging time and stay off unless enabled by the user.

Full Disk Access, where needed for a comprehensive scan, must be granted by the user in System Settings → Privacy & Security. The app works with whatever paths it can read without it.
