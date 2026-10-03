#!/bin/zsh
# Build a double-clickable, ad-hoc-signed DiskMap.app (no Apple Developer account).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DIST="$ROOT/dist"
APP="$DIST/DiskMap.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

echo "==> swift build -c release --product DiskMapApp"
swift build -c release --product DiskMapApp

BIN="$ROOT/.build/release/DiskMapApp"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
# Sparkle (TASK-083): updates work only when both are given; otherwise the app
# has no feed and never contacts any server. The private key never enters the
# repo — sign releases with Sparkle's sign_update on the maintainer's Mac.
FEED_URL="${DISKMAP_FEED_URL:-}"
PUBLIC_KEY="${DISKMAP_SPARKLE_PUBLIC_KEY:-}"
if [ ! -x "$BIN" ]; then
  echo "missing release binary at $BIN" >&2
  exit 1
fi

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"
cp "$BIN" "$MACOS/DiskMap"
chmod +x "$MACOS/DiskMap"

# App icon, drawn by Sources/IconRender (scripts/make-icon.sh).
cp "$ROOT/Resources/AppIcon.icns" "$RES/AppIcon.icns"

# Sparkle.framework next to the binary, found through @executable_path.
mkdir -p "$CONTENTS/Frameworks"
cp -R "$ROOT/.build/release/Sparkle.framework" "$CONTENTS/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS/DiskMap" 2>/dev/null || true

# SwiftPM resource bundle (quick-wins JSON)
for bundle in "$ROOT"/.build/release/DiskMap_*.bundle; do
  if [ -d "$bundle" ]; then
    cp -R "$bundle" "$RES/"
  fi
done

BUNDLE_ID="${DISKMAP_BUNDLE_ID:-com.ayushjo.diskmap}"
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>DiskMap</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>DiskMap</string>
  <key>CFBundleDisplayName</key>
  <string>DiskMap</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD_NUMBER}</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <!-- Updates are opt-in: never checked unless the user turns it on. -->
  <key>SUEnableAutomaticChecks</key>
  <false/>${FEED_URL:+
  <key>SUFeedURL</key>
  <string>${FEED_URL}</string>}${PUBLIC_KEY:+
  <key>SUPublicEDKey</key>
  <string>${PUBLIC_KEY}</string>}
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <!-- TASK-063: accept folders dropped on the Dock icon. Rank None: DiskMap
       can open folders but never becomes the default app for them. -->
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>
      <string>Folder</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>None</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.folder</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST

printf 'APPL????' > "$CONTENTS/PkgInfo"

echo "==> ad-hoc codesign"
codesign --force --deep --sign - "$APP"
codesign -dv --verbose=2 "$APP" 2>&1 | head -20

echo "==> verify"
codesign --verify --deep --strict "$APP" && echo "signature ok (ad-hoc)"

DMG="$DIST/DiskMap-${VERSION}.dmg"
echo "==> $DMG"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/diskmap-dmg.XXXXXX")"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "DiskMap ${VERSION}" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "==> done: $APP (version ${VERSION}, build ${BUILD_NUMBER}) and $DMG"
echo "First launch: right-click the app → Open (Gatekeeper unidentified-developer warning)."
echo "No Apple Developer account required for this personal-use path."
