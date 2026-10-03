#!/bin/bash
# Renders every screen for visual regression (TASK-084), then compares with
# the baselines when they exist.
#
#   scripts/render-all.sh            render into build/visual, compare with docs/visual-baseline
#   scripts/render-all.sh --update   render and copy the result into docs/visual-baseline
#
# Deterministic: a fixed fixture (scripts/make-visual-fixture.sh), fixed
# volume figures, no scan cache or history, default text size and clone
# accounting (`--deterministic`). Applications and Snapshots are left out:
# they list what is installed / saved on this Mac. Baselines are meant to be
# produced on CI (fonts and antialiasing differ between machines).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=build/visual
BASELINE=docs/visual-baseline
FIXTURE=$(scripts/make-visual-fixture.sh)
swift build --product DiskMapApp >/dev/null
swift build -c release --product ImageDiff >/dev/null
BIN=$(swift build --show-bin-path)
rm -rf "$OUT"; mkdir -p "$OUT"
DESTINATIONS=overview,find,search,regenerableData,biggestFiles,biggestFolders,forgottenFiles,duplicates,cleanSafe,cleanCaches,cleanDownloads,cleanMedia,fileBrowser,visualize,developerStorage
for appearance in light dark hc-light hc-dark; do
  # Defaults-style pairs (-Key value) never go here: after a valueless flag
  # macOS would take the value as a document to open.
  "$BIN/DiskMapApp" --scan "$FIXTURE" --snapshot-dir "$OUT" --appearance "$appearance" \
    --snapshot-size 1280x820 --snapshot-destinations "$DESTINATIONS" --explore-modes all --settle 2 --deterministic \
    >/dev/null 2>&1
  echo "rendered $appearance"
done
ls "$OUT"/*.png | wc -l | xargs echo "images:"
if [ "${1:-}" = "--update" ]; then
  rm -rf "$BASELINE"; mkdir -p "$BASELINE"; cp "$OUT"/*.png "$BASELINE"/
  echo "baselines updated in $BASELINE"
elif [ -d "$BASELINE" ]; then
  "$(swift build -c release --show-bin-path)/ImageDiff" "$BASELINE" "$OUT" "$OUT/diff"
else
  echo "no baselines yet ($BASELINE) — run with --update to create them"
fi
