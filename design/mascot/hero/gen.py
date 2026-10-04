"""Turns the real app renders (accessibility frames + sRGB screenshot) into hero-data.ts."""
import json, re, subprocess, sys
H = sys.argv[1]; OUT = sys.argv[2]
tile_re = re.compile(r'AXButton "([^,]+), ([\d.]+) GB, \d+ percent" @([\d.]+),([\d.]+),([\d.]+),([\d.]+)')
def parse(state):
    txt = open(f"{H}/{state}/visualize-ax.txt").read()
    tiles = {m[0]: [float(m[2]), float(m[3]), float(m[4]), float(m[5])] for m in tile_re.findall(txt)}
    sizes = {m[0]: m[1] for m in tile_re.findall(txt)}
    header = re.search(r'value="([\d.]+ GB  ·  \d+ items)"', txt).group(1)
    return tiles, sizes, header
states = [parse(f"state{k}") for k in range(4)]
tiles0, sizes, _ = states[0]
# Gradient per tile: sample just inside the top and bottom, away from the label.
pts = []
for name, (x, y, w, h) in tiles0.items():
    pts += [f"{x + w - 8},{y + 4}", f"{x + w - 8},{y + h - 4}"]
out = subprocess.run([f"{H}/sample", f"{H}/state0/srgb.png", *pts], capture_output=True, text=True).stdout.split("\n")
cols = [l.split()[-1] for l in out if l.strip()]
colors = {name: [cols[2 * i], cols[2 * i + 1]] for i, name in enumerate(tiles0)}
# Colours as a browser decodes the published JPEG (sampled with a canvas), which is what
# the live tiles must match; they win over the AppKit samples above when present.
import os
browser = os.path.join(os.path.dirname(os.path.abspath(__file__)), "colors.json")
if os.path.exists(browser): colors.update(json.load(open(browser)))
txt0 = open(f"{H}/state0/visualize-ax.txt").read()
def frame(label):
    line = next(l for l in txt0.split("\n") if label in l)
    return [float(v) for v in re.search(r'@([\d.]+),([\d.]+),([\d.]+),([\d.]+)', line).groups()]
data = {
    "window": [980, 760],
    "treemap": frame('AXGroup "Treemap of alex"'),
    "cleanup": frame('AXButton "Cleanup"'),
    "header": frame('value="190.74 GB'),
    "canvas": "#F8F7F3",
    "order": list(tiles0),
    "sizes": sizes,
    "colors": colors,
    "states": [{"header": hdr, "tiles": t} for t, _, hdr in states],
}
ts = ("// Generated from real freedisk.space renders of the hero demo folder (alex/), by\n"
      "// design/mascot/hero/gen.py in the DiskMap repo: accessibility frames + sRGB pixels.\n"
      "export const HERO = " + json.dumps(data, ensure_ascii=False, indent=1) + " as const;\n")
open(OUT, "w").write(ts)
print("ok", list(tiles0), [s[2] for s in states])
