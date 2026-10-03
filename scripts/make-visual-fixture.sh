#!/bin/bash
# Deterministic folder tree for visual regression renders (TASK-084).
# Fixed names and sizes; modification dates set relative to *now*, so text
# like "27 days ago" or "over a year" reads the same whichever day it runs.
# Usage: scripts/make-visual-fixture.sh [dir]   (default /tmp/DiskMapVisualFixture)
# The folder is rebuilt from scratch each time; it lives outside the repo.
set -euo pipefail
ROOT="${1:-/tmp/DiskMapVisualFixture}"
case "$ROOT" in
  /tmp/*|/private/tmp/*|"${TMPDIR:-/nonexistent}"*) ;;
  *) echo "refusing to rebuild $ROOT: use a folder under /tmp" >&2; exit 2 ;;
esac
rm -rf "$ROOT"
python3 - "$ROOT" <<'PY'
import os, sys, time
root = sys.argv[1]
now = time.time()
day = 86400
# path, size in bytes, age in days
files = [
    ("Movies/Holiday 2023.mov", 180_000_000, 400),
    ("Movies/Talk recording.mp4", 95_000_000, 27),
    ("Movies/clips/clip-01.mp4", 12_000_000, 4),
    ("Movies/clips/clip-02.mp4", 9_000_000, 4),
    ("Downloads/installer-old.dmg", 70_000_000, 120),
    ("Downloads/report.pdf", 2_400_000, 3),
    ("Downloads/archive-2022.zip", 40_000_000, 800),
    ("Documents/thesis.pdf", 6_500_000, 200),
    ("Documents/notes.txt", 12_000, 2),
    ("Documents/photos/IMG_0001.jpg", 3_200_000, 60),
    ("Documents/photos/IMG_0002.jpg", 3_100_000, 60),
    ("Projects/webapp/node_modules/react/index.js", 1_500_000, 90),
    ("Projects/webapp/node_modules/lodash/lodash.js", 2_200_000, 90),
    ("Projects/webapp/src/App.swift", 30_000, 10),
    ("Projects/webapp/package-lock.json", 800_000, 10),
    ("Projects/old-tool/build/output.o", 25_000_000, 500),
    ("Library/Caches/com.example.browser/cache.db", 30_000_000, 1),
    ("Library/Logs/app.log", 60_000_000, 1),
    (".npm/_cacache/content.bin", 15_000_000, 30),
]
for rel, size, age in files:
    path = os.path.join(root, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as handle:
        # Distinct bytes per file, so nothing reads as a duplicate by accident.
        chunk = (rel.encode() * (65536 // max(1, len(rel)) + 1))[:65536]
        left = size
        while left > 0:
            handle.write(chunk[:min(left, len(chunk))])
            left -= len(chunk)
    stamp = now - age * day
    os.utime(path, (stamp, stamp))
# One real duplicate pair.
for rel in ("Downloads/copy-a.bin", "Documents/copy-b.bin"):
    path = os.path.join(root, rel)
    with open(path, "wb") as handle:
        handle.write(b"same bytes" * 300_000)
    os.utime(path, (now - 15 * day, now - 15 * day))
# Folder dates last, children first, so writes above do not touch them.
for current, dirs, _ in sorted(os.walk(root), key=lambda entry: -entry[0].count(os.sep)):
    os.utime(current, (now - 2 * day, now - 2 * day))
PY
echo "$ROOT"
