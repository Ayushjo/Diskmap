#!/bin/zsh
# Mounts an in-memory ExFAT volume at /Volumes/DISKMAP for TASK-027.
# Prefer this over `hdiutil create` — on this Mac that fails with
# "Operation not permitted" even in Terminal.app.
set -euo pipefail
VOL="/Volumes/DISKMAP"
if [ -d "$VOL" ]; then
  echo "Already mounted at $VOL"
else
  # ~1GB RAM disk (512-byte sectors)
  DEV=$(hdiutil attach -nomount ram://2097152 | awk '{print $1}')
  echo "Formatting $DEV as ExFAT DISKMAP..."
  # ExFAT names are short (≤11 chars) — "DISKMAP" fits.
  diskutil erasevolume ExFAT DISKMAP "$DEV"
fi
EDGE="$VOL/edge-cases"
mkdir -p "$EDGE/dups" "$EDGE/tree/sub"
python3 - <<'PY'
import os
base="/Volumes/DISKMAP/edge-cases"
os.makedirs(base, exist_ok=True)
open(os.path.join(base, "cafe\u0301.txt"), "w").write("unicode-combining\n")
print("unicode ok")
PY
DEEP="$EDGE/deep"
for i in $(seq 1 40); do DEEP="$DEEP/d$i"; done
mkdir -p "$DEEP"
echo deep-ok > "$DEEP/leaf.txt"
echo 'same-bytes-payload-for-hash' > "$EDGE/dups/a.bin"
cp "$EDGE/dups/a.bin" "$EDGE/dups/b.bin"
cp -c "$EDGE/dups/a.bin" "$EDGE/dups/c-cloneattempt.bin" 2>"$EDGE/dups/cp-c.err" || true
for i in $(seq 1 50); do echo "f$i" > "$EDGE/tree/f$i.txt"; echo "s$i" > "$EDGE/tree/sub/s$i.txt"; done
if [ ! -f "$EDGE/large-64m.bin" ]; then
  dd if=/dev/zero of="$EDGE/large-64m.bin" bs=1048576 count=64
fi
diskutil info "$VOL" | grep -E 'File System|Mount Point|Volume Name|Type \(Bundle\)' || true
echo "Ready at $VOL (RAM-backed ExFAT). Detach later with: diskutil eject DISKMAP"
