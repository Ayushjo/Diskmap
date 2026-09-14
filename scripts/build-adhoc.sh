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
if [ ! -x "$BIN" ]; then
  echo "missing release binary at $BIN" >&2
  exit 1
fi

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"
cp "$BIN" "$MACOS/DiskMap"
chmod +x "$MACOS/DiskMap"

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
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$CONTENTS/PkgInfo"

echo "==> ad-hoc codesign"
codesign --force --deep --sign - "$APP"
codesign -dv --verbose=2 "$APP" 2>&1 | head -20

echo "==> done: $APP"
echo "First launch: right-click the app → Open (Gatekeeper unidentified-developer warning)."
echo "No Apple Developer account required for this personal-use path."
