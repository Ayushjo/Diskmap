#!/bin/bash
# Developer ID signing + notarization (TASK-083). Not usable yet: there is no
# Apple Developer account. It stops with a clear message unless both are set:
#   DEVELOPER_ID      "Developer ID Application: Name (TEAMID)"
#   NOTARY_PROFILE    a keychain profile made with `xcrun notarytool store-credentials`
# Run after scripts/build-adhoc.sh. Nothing here touches the network until
# notarytool submits, and only when you run it.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${DEVELOPER_ID:-}" ] || [ -z "${NOTARY_PROFILE:-}" ]; then
  echo "notarize.sh: DEVELOPER_ID and NOTARY_PROFILE are not set — skipping." >&2
  echo "Ad-hoc builds (scripts/build-adhoc.sh) need right-click → Open on first launch." >&2
  exit 3
fi
VERSION="$(tr -d '[:space:]' < VERSION)"
APP=dist/DiskMap.app
DMG="dist/DiskMap-${VERSION}.dmg"
codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
codesign --verify --deep --strict "$APP"
rm -f "$DMG"
STAGE="$(mktemp -d)"; cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "DiskMap ${VERSION}" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
echo "notarized: $DMG"
