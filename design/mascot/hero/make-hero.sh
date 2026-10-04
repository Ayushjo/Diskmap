#!/bin/zsh
# A small home folder for the website hero: everyday folders plus three bits of
# top-level clutter Dusty sweeps (.cache, Installers, .npm). Sparse files: big
# logical sizes, almost no real disk use.
set -e
R=/tmp/FreediskHero/alex
[[ "$1" == keep ]] || { /bin/rm -rf /tmp/FreediskHero; }
mkdir -p $R
f() { mkdir -p "$R/$(dirname "$1")"; mkfile -n "$2" "$R/$1"; touch -t "$(date -v-"$3"d +%Y%m%d%H%M)" "$R/$1"; }
f "Movies/Wedding Film — Final 4K.mov" 27100m 300
f "Movies/Iceland Ring Road.mov" 13400m 420
f "Movies/Screen Recordings/Keynote Rehearsal.mov" 7600m 30
f "Pictures/Photos Library.photoslibrary/originals.db" 23300m 4
f "Pictures/Scans/Passport scan.tiff" 7800m 700
f "Library/Application Support/Docker/Docker.raw" 17200m 2
f "Library/Mail/V10/mailbox.mbox" 8900m 1
f "Downloads/Project footage.zip" 11300m 60
f "Downloads/Client handoff.zip" 7900m 45
f "Projects/webapp/assets/hero-video.mp4" 8800m 12
f "Projects/ml-experiments/data/train.parquet" 6300m 25
f "Music/Logic/Album stems.logicx" 11100m 90
f "Documents/Clients/Pitch Deck.key" 4600m 20
f "Documents/Thesis/Thesis Final.pdf" 3500m 400
f ".cache/huggingface/hub/model.safetensors" 6200m 210
f ".cache/pip/http/wheels.bin" 3400m 260
f "Installers/macOS Sequoia.dmg" 4300m 520
f "Installers/Xcode_16.xip" 3100m 480
f ".npm/_cacache/content-v2/sha512.pack" 6100m 330
