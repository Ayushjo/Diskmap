#!/bin/bash
# Renders the app icon from code (Sources/IconRender) and builds
# Resources/AppIcon.icns. Variant 4 (the logo mark, docs/brand/) is the
# default; 1–3 are the earlier treemap alternatives in docs/icon/.
# Usage: scripts/make-icon.sh [1|2|3|4]
set -euo pipefail
cd "$(dirname "$0")/.."
VARIANT="${1:-4}"
swift build --product IconRender >/dev/null
BIN=$(swift build --show-bin-path)/IconRender
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"
"$BIN" "$VARIANT" "$ICONSET"
mkdir -p Resources
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
"$BIN" --previews docs/icon
echo "Resources/AppIcon.icns (variant $VARIANT); previews in docs/icon/"
