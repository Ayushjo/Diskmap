"""Dusty, the freedisk.space mascot. Generates every pose from one set of shapes.

    python3 dusty.py          -> svg/*.svg + parts.json (used by index.html)
"""
import json, math, os, random

INK = "#2B2440"
EDGE = 172      # where the ledge cuts a peeking Dusty
EXTRA = "var(--dusty-ink, #2B2440)"   # marks drawn on the page, not on Dusty
CLEAN = dict(fill="#CEC4F7", shade="#B4A6F1", light="#E6E0FC", fur="#8E7DE3",
             ear="#F6C4DA", blush="#F7A8C8", hatch="#E583AB", nose="#F08DB4", paw="#E4DEFC")
DUSTY = dict(fill="#D6D2CA", shade="#BEB9AF", light="#E4E1DA", fur="#8F897F",
             ear="#D9CDCB", blush=None, hatch=None, nose="#BFA9AE", paw="#E2DFD8")

def f(v): return f"{v:.1f}".rstrip("0").rstrip(".")

def smooth(pts, closed=True):
    """Catmull-Rom through the points, as cubic Béziers."""
    n = len(pts); d = f"M{f(pts[0][0])},{f(pts[0][1])}"
    rng = range(n) if closed else range(n - 1)
    for i in rng:
        p0 = pts[(i - 1) % n] if closed or i > 0 else pts[0]
        p1 = pts[i]; p2 = pts[(i + 1) % n]
        p3 = pts[(i + 2) % n] if closed or i + 2 < n else pts[-1]
        c1 = (p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6)
        c2 = (p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6)
        d += f"C{f(c1[0])},{f(c1[1])} {f(c2[0])},{f(c2[1])} {f(p2[0])},{f(p2[1])}"
    return d + ("Z" if closed else "")

def scallop(pts, bump, rnd, jitter=0.25):
    """Fluffy outline: a rounded bump between each pair of points."""
    n = len(pts)
    area = sum(pts[i][0] * pts[(i + 1) % n][1] - pts[(i + 1) % n][0] * pts[i][1] for i in range(n))
    s = 1 if area > 0 else -1
    d = f"M{f(pts[0][0])},{f(pts[0][1])}"
    for i in range(n):
        a, b = pts[i], pts[(i + 1) % n]
        dx, dy = b[0] - a[0], b[1] - a[1]; L = math.hypot(dx, dy) or 1
        nx, ny = s * dy / L, -s * dx / L
        h = bump * (1 + rnd.uniform(-jitter, jitter)) * 2
        sl = rnd.uniform(-0.12, 0.12) * L          # lean each bump a little: hand-made
        cx, cy = (a[0] + b[0]) / 2 + nx * h + dx / L * sl, (a[1] + b[1]) / 2 + ny * h + dy / L * sl
        d += f"Q{f(cx)},{f(cy)} {f(b[0])},{f(b[1])}"
    return d + "Z"

def blob(cx, cy, rx, ry, n, rnd, wob=0.0, flat=None, start=-math.pi / 2):
    pts = []
    for i in range(n):
        a = start + 2 * math.pi * i / n + rnd.uniform(-wob, wob) * 0.05
        r = 1 + rnd.uniform(-wob, wob) * 0.03
        x, y = cx + rx * r * math.cos(a), cy + ry * r * math.sin(a)
        if flat is not None and y > flat: y = flat + (y - flat) * 0.25
        pts.append((x, y))
    return pts

def bez(p, t):
    u = 1 - t
    return tuple(u**3 * p[0][k] + 3 * u * u * t * p[1][k] + 3 * u * t * t * p[2][k] + t**3 * p[3][k] for k in (0, 1))

def ear_outline(c, W, t0=0.0, t1=0.9, rnd=None, wob=0.25, k=14):
    """Both edges of the ear along its centre curve, closed with a round cap at the tip."""
    def frame(t):
        x, y = bez(c, t)
        x2, y2 = bez(c, min(1, t + 0.01)); x1, y1 = bez(c, max(0, t - 0.01))
        tx, ty = x2 - x1, y2 - y1; L = math.hypot(tx, ty) or 1
        return x, y, tx / L, ty / L
    def width(t): return W * (0.72 + 0.34 * math.sin(math.pi * t)) / 2
    left, right = [], []
    for i in range(k + 1):
        t = t0 + (t1 - t0) * i / k
        x, y, tx, ty = frame(t)
        w = width(t); j = (rnd.uniform(-wob, wob) if rnd else 0) * (1 - t / t1)
        left.append((x - ty * (w + j), y + tx * (w + j)))
        right.append((x + ty * (w - j), y - tx * (w - j)))
    x, y, tx, ty = frame(t1); w = width(t1)
    a0 = math.atan2(tx, -ty)
    cap = [(x + w * math.cos(a0 - math.pi * i / 6), y + w * math.sin(a0 - math.pi * i / 6)) for i in range(1, 6)]
    return left + cap + right[::-1]

EARS = {
    "up":    ((102, 112), (98, 74), (88, 42), (86, 22)),
    "upR":   ((138, 112), (142, 74), (152, 42), (154, 22)),
    "flopR": ((138, 112), (146, 64), (180, 40), (192, 74)),
    "flopL": ((102, 112), (94, 64), (60, 40), (48, 74)),
    "droopL": ((100, 116), (86, 84), (60, 80), (46, 106)),
    "droopR": ((140, 116), (154, 84), (180, 80), (194, 106)),
    "perkL": ((102, 112), (96, 70), (84, 34), (80, 12)),
    "bentR": ((138, 112), (146, 70), (160, 44), (176, 46)),
}

def ear(name, pal, rnd, cls):
    c = EARS[name]
    W = 31
    outer = ear_outline(c, W, rnd=rnd)
    inner = ear_outline(c, W * 0.44, 0.2, 0.8, rnd=rnd, wob=0.15)
    base = c[0]
    return (f'<g class="{cls}" style="transform-origin:{base[0]}px {base[1]}px">'
            f'<path d="{smooth(outer)}" fill="{pal["fill"]}" stroke="{INK}" stroke-width="3" stroke-linejoin="round"/>'
            f'<path d="{smooth(inner)}" fill="{pal["ear"]}"/>'
            f'</g>')

def star(x, y, r, col):
    k = r * 0.28
    return (f'<path d="M{f(x)},{f(y-r)}Q{f(x+k)},{f(y-k)} {f(x+r)},{f(y)}Q{f(x+k)},{f(y+k)} {f(x)},{f(y+r)}'
            f'Q{f(x-k)},{f(y+k)} {f(x-r)},{f(y)}Q{f(x-k)},{f(y-k)} {f(x)},{f(y-r)}Z" fill="{col}"/>')

def eyes(kind, look=(0, 0)):
    out = []
    for i, x in enumerate((98, 142)):
        y = 150; lx, ly = look
        if kind == "dot":
            out.append(f'<g class="eye"><ellipse cx="{x+lx}" cy="{y+ly}" rx="7.4" ry="9.2" fill="{INK}"/>'
                       f'<circle cx="{f(x+lx-2.3)}" cy="{f(y+ly-3.5)}" r="2.7" fill="#fff"/>'
                       f'<circle cx="{f(x+lx+2.5)}" cy="{f(y+ly+3.3)}" r="1.2" fill="#fff" opacity=".85"/></g>')
        elif kind == "wide":
            out.append(f'<g class="eye"><ellipse cx="{x}" cy="{y-1}" rx="8.6" ry="10.6" fill="{INK}"/>'
                       f'<circle cx="{x-2.6}" cy="{y-5}" r="3.3" fill="#fff"/>'
                       f'<circle cx="{x+3}" cy="{y+3}" r="1.6" fill="#fff"/></g>')
        elif kind == "happy":
            out.append(f'<path d="M{x-7.5},{y+2.5}Q{x},{y-8} {x+7.5},{y+2.5}" fill="none" stroke="{INK}" stroke-width="3.4" stroke-linecap="round"/>')
        elif kind == "closed":
            out.append(f'<path d="M{x-7},{y}Q{x},{y+6} {x+7},{y}" fill="none" stroke="{INK}" stroke-width="3" stroke-linecap="round"/>'
                       f'<path d="M{x+6.5 if i else x-6.5},{y+1}l{3 if i else -3},2" stroke="{INK}" stroke-width="2" stroke-linecap="round"/>')
        elif kind == "lidded":
            out.append(f'<path d="M{x-7},{y-1}A7,8 0 0 0 {x+7},{y-1}Z" fill="{INK}"/>'
                       f'<circle cx="{x-2}" cy="{y+2.4}" r="1.6" fill="#fff" opacity=".8"/>'
                       f'<path d="M{x-8.5},{y-1.5}Q{x},{y-3.4} {x+8.5},{y-1.5}" fill="none" stroke="{INK}" stroke-width="2.6" stroke-linecap="round"/>')
    return "".join(out)

def mouth(kind):
    nose = (f'<path d="M116.6,158.6Q120,156.6 123.4,158.6Q122.6,162.2 120,162.6Q117.4,162.2 116.6,158.6Z" '
            f'fill="NOSE" stroke="{INK}" stroke-width="1.6" stroke-linejoin="round"/>')
    if kind == "w":
        m = f'<path d="M120,162.6V164.6M113.4,163.6Q116.7,168 120,164.6Q123.3,168 126.6,163.6" fill="none" stroke="{INK}" stroke-width="2.3" stroke-linecap="round" stroke-linejoin="round"/>'
    elif kind == "smile":
        m = (f'<path d="M112.5,164.5Q120,166 127.5,164.5Q127,175.5 120,175.8Q113,175.5 112.5,164.5Z" fill="{INK}"/>'
             f'<path d="M115.5,172.2Q120,169.2 124.5,172.2Q122.8,175.3 120,175.4Q117.2,175.3 115.5,172.2Z" fill="#F08DB4"/>')
    elif kind == "o":
        m = f'<ellipse cx="120" cy="168.5" rx="3.4" ry="4.2" fill="{INK}"/>'
    elif kind == "tiny":
        m = f'<ellipse cx="120" cy="167" rx="2.2" ry="1.8" fill="{INK}"/>'
    elif kind == "flat":
        m = f'<path d="M113,167Q116.5,165 120,167Q123.5,169 127,166.6" fill="none" stroke="{INK}" stroke-width="2.3" stroke-linecap="round"/>'
    elif kind == "wobble":
        m = f'<path d="M111.5,168.5q2.1,-2.6 4.2,0t4.2,0t4.2,0t4.2,0" fill="none" stroke="{INK}" stroke-width="2.3" stroke-linecap="round" stroke-linejoin="round"/>'
    return nose + m

def dusty(state="clean", face="dot", mouth_kind="w", ears=("up", "flopR"), extras=(), tilt=0,
          seed=7, look=(0, 0), squash=1.0, uid="d", small=False, peek=False):
    """peek: Dusty behind an edge at y=EDGE, only the top showing, paws gripping the edge."""
    pal = CLEAN if state == "clean" else DUSTY
    rnd = random.Random(seed)
    cx, cy, rx, ry = 120, 150, 62, 54
    n, bump = (24, 4.6) if state == "clean" else (19, 6.4)
    if small: n, bump = 13, 7
    body_pts = blob(cx, cy, rx, ry, n, rnd, wob=1 if state == "clean" else 3, flat=cy + ry * 0.86)
    body = scallop(body_pts, bump, rnd, jitter=0.25 if state == "clean" else 0.6)
    tail = scallop(blob(180, 182, 14, 13, 8, rnd), 3.2, rnd)
    tuft = scallop(blob(121, 94, 15, 8, 6, rnd), 3.6, rnd)
    paw_y = EDGE if peek else 199
    paws = "".join(
        f'<g class="paw paw-{side}">'
        f'<path d="{scallop(blob(px, paw_y, 11.5, 7.6, 7, rnd), 1.7, rnd)}" fill="{pal["paw"]}" stroke="{INK}" stroke-width="2.6" stroke-linejoin="round"/>'
        f'<path d="M{px-3},{paw_y-2.5}v3.4M{px+3},{paw_y-2.5}v3.4" stroke="{pal["fur"]}" stroke-width="1.5" stroke-linecap="round"/></g>'
        for px, side in ((104, "l"), (136, "r")))
    fur = ""
    if not small:
        marks = [(86, 120), (104, 109), (148, 113), (70, 152), (170, 150), (96, 186), (146, 188), (164, 128)]
        for (x, y) in marks:
            x += rnd.uniform(-1.5, 1.5); y += rnd.uniform(-1.5, 1.5)
            fur += f'<path d="M{f(x-6)},{f(y)}q3,3.4 6,0q3,3.4 6,0" fill="none" stroke="{pal["fur"]}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" opacity=".75"/>'
    blush = ""
    if pal["blush"] and face != "lidded":
        for x in (85, 155):
            blush += (f'<ellipse cx="{x}" cy="163" rx="9.5" ry="5.4" fill="{pal["blush"]}" opacity=".8"/>'
                      + "".join(f'<path d="M{x-5+i*4},{165.2}l2.2,-4.4" stroke="{pal["hatch"]}" stroke-width="1.4" stroke-linecap="round"/>' for i in range(3)))
    clip = f"{uid}-c"
    if peek:
        # The edge stays straight: only the inner group leans, inside a fixed clip.
        g = [f'<g class="peek"><clipPath id="{uid}-edge"><rect x="-60" y="-60" width="360" height="{EDGE + 60}"/></clipPath>',
             f'<g clip-path="url(#{uid}-edge)"><g class="dusty" style="transform-origin:120px {EDGE}px;transform:rotate({tilt}deg) scaleY({squash})">']
    else:
        g = [f'<ellipse class="shadow" cx="120" cy="207" rx="54" ry="6.5" fill="{EXTRA}" opacity=".10"/>',
             f'<g class="dusty" style="transform-origin:120px 206px;transform:rotate({tilt}deg) scaleY({squash})">']
    g.append(f'<path d="{tail}" fill="{pal["fill"]}" stroke="{INK}" stroke-width="3" stroke-linejoin="round"/>')
    g.append(ear(ears[0], pal, rnd, "ear ear-l"))
    g.append(ear(ears[1], pal, rnd, "ear ear-r"))
    g.append(f'<path d="{tuft}" fill="{pal["fill"]}" stroke="{INK}" stroke-width="3" stroke-linejoin="round"/>')
    g.append(f'<clipPath id="{clip}"><path d="{body}"/></clipPath>')
    g.append(f'<path d="{body}" fill="{pal["fill"]}"/>')
    g.append(f'<g clip-path="url(#{clip})"><ellipse cx="150" cy="214" rx="90" ry="40" fill="{pal["shade"]}"/>'
             f'<ellipse cx="96" cy="112" rx="38" ry="17" fill="{pal["light"]}" opacity=".45"/></g>')
    g.append(fur)
    g.append(f'<path d="{body}" fill="none" stroke="{INK}" stroke-width="3.2" stroke-linejoin="round"/>')
    if not small:
        g.append(f'<path d="M85,131Q89,118 101,111" fill="none" stroke="#fff" stroke-width="3.6" stroke-linecap="round" opacity=".75"/>')
    g.append(blush)
    g.append(f'<g class="face">{eyes(face, look)}{mouth(mouth_kind).replace("NOSE", pal["nose"])}</g>')
    if peek: g.append("</g></g>")
    g.append(paws)
    if state == "dusty":
        r2 = random.Random(seed + 1)
        for _ in range(9):
            a = r2.uniform(0, 2 * math.pi); d = r2.uniform(0.2, 0.8)
            x, y = cx + rx * d * math.cos(a), cy + ry * d * math.sin(a)
            if abs(x - 120) < 32 and 138 < y < 176: continue
            g.append(f'<circle cx="{f(x)}" cy="{f(y)}" r="{f(r2.uniform(1, 2.1))}" fill="#7E786E" opacity=".7"/>')
        g.append(f'<path d="M156,104q6,-10 2,-18q-3,-6 4,-10" fill="none" stroke="{INK}" stroke-width="1.6" stroke-linecap="round"/>')
        g.append(f'<path d="M66,160q-9,2 -12,9" fill="none" stroke="{INK}" stroke-width="1.6" stroke-linecap="round"/>')
    for e in extras:
        if e == "sparkles":
            g.append('<g class="sparkles">' + star(36, 104, 9, "#7966DA") + star(210, 138, 6.5, "#7966DA")
                     + star(56, 62, 4.6, "#B4A6F1") + star(216, 96, 4.2, "#B4A6F1") + "</g>")
        if e == "zzz":
            g.append(f'<g fill="none" stroke="{EXTRA}" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round">'
                     f'<path d="M190,58h10l-10,12h10"/><path d="M208,38h7l-7,8.4h7" opacity=".7"/><path d="M222,22h5l-5,6h5" opacity=".45"/></g>')
        if e == "sweat":
            g.append(f'<path d="M176,112q7,9 4,14.5q-4,5 -8.5,1q-3,-4 4.5,-15.5Z" fill="#CFE2FA" stroke="{INK}" stroke-width="2" stroke-linejoin="round"/>'
                     f'<path d="M175,124q-1,-2.6 1,-5" stroke="#fff" stroke-width="1.6" stroke-linecap="round"/>')
        if e == "question":
            g.append(f'<path d="M180,70q0,-11 10,-11q10,0 10,9q0,6 -7,9q-3,1.4 -3,6" fill="none" stroke="{EXTRA}" stroke-width="3" stroke-linecap="round"/>'
                     f'<circle cx="190" cy="92" r="2.4" fill="{EXTRA}"/>')
        if e == "motes":
            r3 = random.Random(seed + 5)
            for (x, y, r) in [(40, 132, 5), (30, 150, 3), (206, 158, 4.5), (214, 140, 2.6), (52, 196, 3.4), (190, 200, 2.8)]:
                if peek and y > EDGE - 8: continue
                g.append(f'<circle cx="{x}" cy="{y}" r="{r}" fill="none" stroke="#9E998F" stroke-width="1.6" opacity=".8"/>')
        if e == "puffs":
            for (x, y, r) in [(28, 118, 7), (212, 104, 6.5), (34, 184, 6), (212, 176, 7.5), (60, 64, 5), (196, 56, 4.5), (24, 152, 5)]:
                if peek and y > EDGE - 10: continue
                cloud = scallop(blob(x, y, r * 1.5, r, 6, random.Random(int(x * y))), r * 0.35, random.Random(int(x)))
                g.append(f'<path d="{cloud}" fill="#E4E1DA" stroke="{INK}" stroke-width="1.8" stroke-linejoin="round"/>')
            g.append(f'<g stroke="{EXTRA}" stroke-width="2.2" stroke-linecap="round"><path d="M44,144l-9,-3"/><path d="M46,158l-10,2"/><path d="M196,146l9,-3"/><path d="M194,160l10,2"/></g>')
    g.append("</g>")
    return "".join(g)

GRIP = (186, 152)   # where Dusty's right paw holds the broom, in Dusty's 240 grid

def broom():
    """A small broom in Dusty's style, held at GRIP and leaning out to the right.
    The outer group is what animates (sweeps) around the grip."""
    wood, bristle, line = "#D9B98A", "#F3E3C1", "#C7A56B"
    b = [f'<g class="broom" style="transform-origin:{GRIP[0]}px {GRIP[1]}px">',
         f'<g transform="translate({GRIP[0]} {GRIP[1]}) rotate(-15)">',
         f'<rect x="-4" y="-94" width="8" height="122" rx="4" fill="{wood}" stroke="{INK}" stroke-width="2.6"/>',
         f'<path d="M-1.4,-86v30M1.6,-40v22" stroke="#fff" stroke-width="1.6" stroke-linecap="round" opacity=".55"/>',
         f'<path d="M-11.5,26Q-14,40 -22,52Q-17,56.5 -11,53Q-6,57.5 0,54Q6,57.5 11,53Q17,56.5 22,52Q14,40 11.5,26Z" fill="{bristle}" stroke="{INK}" stroke-width="2.6" stroke-linejoin="round"/>',
         f'<path d="M-6,31Q-8,42 -12,50M0,31V51M6,31Q8,42 12,50" fill="none" stroke="{line}" stroke-width="1.6" stroke-linecap="round"/>',
         f'<rect x="-12.5" y="19" width="25" height="9" rx="3.5" fill="#7966DA" stroke="{INK}" stroke-width="2.4"/>',
         f'<path d="M-8,23.5h16" stroke="#B4A6F1" stroke-width="1.4" stroke-linecap="round"/>',
         f'<ellipse cx="0" cy="-2" rx="9.5" ry="7.5" fill="{CLEAN["paw"]}" stroke="{INK}" stroke-width="2.4"/>',
         f'<path d="M-3,-4.5v3.4M3,-4.5v3.4" stroke="{CLEAN["fur"]}" stroke-width="1.4" stroke-linecap="round"/>',
         '</g></g>']
    return "".join(b)

def specks():
    """Dust Dusty picks up while sweeping. Each speck flies off on its own when Dusty shakes."""
    rnd = random.Random(11)
    pts = [(82, 116), (101, 104), (150, 108), (165, 126), (71, 148), (172, 150), (90, 184), (152, 188),
           (126, 98), (178, 172), (64, 172), (118, 190), (140, 96), (84, 138)]
    out = ['<g class="specks">']
    for (x, y) in pts:
        dx, dy = (x - 120) * rnd.uniform(.5, .9), (y - 150) * rnd.uniform(.5, .9) - rnd.uniform(10, 30)
        r = rnd.uniform(1.4, 2.6)
        out.append(f'<circle class="speck" cx="{x}" cy="{y}" r="{f(r)}" fill="#8F897F" style="--dx:{f(dx)}px;--dy:{f(dy)}px"/>')
    out.append(f'<path class="speck" d="M150,124q5,-3 8,1q3,4 8,1" fill="none" stroke="#8F897F" stroke-width="1.5" stroke-linecap="round" style="--dx:30px;--dy:-30px"/>')
    out.append(f'<path class="speck" d="M76,160q4,4 9,2" fill="none" stroke="#8F897F" stroke-width="1.5" stroke-linecap="round" style="--dx:-30px;--dy:-14px"/>')
    out.append("</g>")
    return "".join(out)

def svg(inner, vb="0 0 240 240", cls=""):
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{vb}" class="{cls}">{inner}</svg>'

POSES = {
    "hello":   dict(face="dot", mouth_kind="w"),
    "happy":   dict(face="happy", mouth_kind="smile", extras=("sparkles",)),
    "curious": dict(face="dot", mouth_kind="o", ears=("perkL", "bentR"), tilt=-8, look=(2.5, -2), extras=("question",)),
    "sleepy":  dict(face="closed", mouth_kind="tiny", ears=("droopL", "droopR"), squash=0.96, extras=("zzz",)),
    "proud":   dict(face="happy", mouth_kind="w", ears=("up", "upR"), extras=("sparkles",)),
    "oops":    dict(face="wide", mouth_kind="wobble", ears=("flopL", "bentR"), extras=("sweat",)),
    "dusty":   dict(state="dusty", face="lidded", mouth_kind="flat", ears=("droopL", "droopR"), extras=("motes",)),
    "shake":   dict(state="dusty", face="closed", mouth_kind="o", ears=("flopL", "flopR"), tilt=6, extras=("puffs",)),
    "small":   dict(small=True),
}

if __name__ == "__main__":
    os.makedirs("svg", exist_ok=True)
    parts = {}
    for name, kw in POSES.items():
        inner = dusty(uid=name, **kw)
        parts[name] = inner
        open(f"svg/dusty-{name}.svg", "w").write(svg(inner))
    # Peeking over an edge: the top of Dusty above a ledge, paws over it.
    peek = dusty(uid="peek", face="dot", look=(0, 2.5), ears=("up", "flopR"))
    parts["peek"] = peek
    json.dump(parts, open("parts.json", "w"))
    print("wrote", len(parts), "poses")
