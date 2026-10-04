#!/bin/bash
# A believable home folder for the promo video. Big files are sparse
# (mkfile -n): they report their size but use almost no disk.
set -euo pipefail
R=/tmp/FreediskDemo
rm -rf "$R"; mkdir -p "$R"
# f <relative path> <size, e.g. 48g / 900m> <age in days>
f() { mkdir -p "$R/$(dirname "$1")"; mkfile -n "$2" "$R/$1"; touch -t "$(date -v-"$3"d +%Y%m%d%H%M)" "$R/$1"; }
# real bytes (for duplicates, which compare contents)
# real zero-filled bytes, for what the Cleanup scene measures on disk
solid() { mkdir -p "$R/$(dirname "$1")"; mkfile "$2" "$R/$1"; touch -t "$(date -v-"$3"d +%Y%m%d%H%M)" "$R/$1"; }
real() { mkdir -p "$R/$(dirname "$1")"; head -c "$2" /dev/urandom > "$R/$1.tmp"; cp "$R/$1.tmp" "$R/$1"; rm "$R/$1.tmp"; touch -t "$(date -v-"$3"d +%Y%m%d%H%M)" "$R/$1"; }

f "Movies/Wedding Film — Final 4K.mov" 48g 720
f "Movies/Travel/Iceland Ring Road 4K.mov" 31g 400
f "Movies/Travel/Japan Drone Footage.mp4" 22g 380
f "Movies/Screen Recordings/Keynote Rehearsal.mov" 9300m 21
f "Movies/Screen Recordings/Product Demo v3.mov" 4g 6
for i in 01 02 03 04 05 06; do f "Pictures/Photos Library.photoslibrary/originals/$i/IMG_48$i.heic" "$((5 + 10#$i))g" "$((30 * 10#$i))"; done
f "Music/Logic Projects/Album Stems.logicx/Media/Stems.wav" 14g 610
f "Downloads/macOS Installer.dmg" 13g 410
f "Downloads/Xcode_15.2.xip" 7800m 300
f "Downloads/ubuntu-24.04-desktop.iso" 6100m 210
f "Downloads/Design Assets 2024.zip" 2400m 520
solid "Downloads/Old Laptop Backup.zip" 780m 900
solid "Downloads/Zoom Recording 2025-03.mp4" 640m 190
f "Library/Developer/Xcode/DerivedData/Atlas-fqzk/Build/Intermediates.noindex/Atlas.build/objects.o" 18g 3
f "Library/Developer/CoreSimulator/Devices/7F2A-iPhone-15-Pro/data/Containers/sim.img" 21g 40
f "Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw" 32g 2
solid "Library/Caches/com.spotify.client/Data/storage.db" 520m 1
f "Library/Caches/Google/Chrome/Default/Cache/data_1" 2100m 1
f "Library/Caches/Homebrew/downloads/bottles.tar" 3400m 12
f "Library/Caches/com.apple.Safari/WebKitCache/blob" 900m 2
f ".npm/_cacache/content-v2/sha512/blob" 2600m 30
i=0; for p in react next typescript webpack esbuild; do i=$((i+1)); f "Projects/webapp/node_modules/$p/dist/bundle.js" "$((200 + ${#p} * 37 + i * 13))m" 14; done
printf '{"name":"webapp","version":"1.0.0"}' > "$R/Projects/webapp/package.json"; echo '{}' > "$R/Projects/webapp/package-lock.json"
echo 'import App' > "$R/Projects/webapp/index.ts"
f "Projects/ios-app/Pods/Firebase/Firebase.framework/Firebase" 2200m 60
echo "platform :ios" > "$R/Projects/ios-app/Podfile"; echo "" > "$R/Projects/ios-app/Podfile.lock"
f "Projects/ml-experiments/.venv/lib/python3.12/site-packages/torch/lib/libtorch.dylib" 3100m 200
echo "torch" > "$R/Projects/ml-experiments/requirements.txt"; touch -t "$(date -v-260d +%Y%m%d%H%M)" "$R/Projects/ml-experiments/requirements.txt"
i=0; for p in gatsby lodash; do i=$((i+1)); f "Projects/old-portfolio/node_modules/$p/index.js" "$((500 + ${#p} * 31 + i * 17))m" 420; done
printf '{"name":"old-portfolio"}' > "$R/Projects/old-portfolio/package.json"; touch -t "$(date -v-430d +%Y%m%d%H%M)" "$R/Projects/old-portfolio/package.json"
f "Documents/Taxes/Tax Return 2023.zip" 1100m 560
f "Documents/Clients/Brand Guidelines.pdf" 380m 80
real "Documents/Thesis Final.pdf" 96000000 700
cp "$R/Documents/Thesis Final.pdf" "$R/Downloads/Thesis Final (1).pdf"; touch -t "$(date -v-650d +%Y%m%d%H%M)" "$R/Downloads/Thesis Final (1).pdf"
real "Desktop/Pitch Deck.key" 64000000 9
cp "$R/Desktop/Pitch Deck.key" "$R/Documents/Clients/Pitch Deck copy.key"
echo "$R"
