"""Exports Dusty for the Mac app: every pose as flat drawing operations.

    python3 export_app.py ../../Sources/DiskMapApp/Kit/DustyArt.swift

The SVG drawings from dusty.py are flattened here, so the app needs no SVG parser:
transforms are baked in, arcs become curves, ellipses and rects become paths.
Only the parts that move keep a role and a pivot (ears, eyes, broom, specks,
sparkles), and the app transforms just those while drawing.
Segments: 0 x y = move, 1 x y = line, 2 cx cy x y = quad, 3 c1x c1y c2x c2y x y = cubic, 4 = close.
"""
import json, math, re, sys
import xml.etree.ElementTree as ET

from dusty import EDGE, GRIP, broom, dusty, specks

FULL = {
    "hello": dict(face="dot", mouth_kind="w"),
    "happy": dict(face="happy", mouth_kind="smile", extras=("sparkles",)),
    "proud": dict(face="happy", mouth_kind="w", ears=("up", "upR"), extras=("sparkles",)),
    "curious": dict(face="dot", mouth_kind="o", ears=("perkL", "bentR"), tilt=-8, look=(2.5, -2), extras=("question",)),
    "sleepy": dict(face="closed", mouth_kind="tiny", ears=("droopL", "droopR"), squash=0.96, extras=("zzz",)),
    "oops": dict(face="wide", mouth_kind="wobble", ears=("flopL", "bentR"), extras=("sweat",)),
    "focus": dict(face="dot", mouth_kind="o", ears=("perkL", "flopR"), look=(2, 3)),
    "shake": dict(face="closed", mouth_kind="o", ears=("flopL", "flopR")),
}
PEEK = {
    "peekHello": dict(face="dot", mouth_kind="w"),
    "peekCurious": dict(face="dot", mouth_kind="o", ears=("perkL", "bentR")),
    "peekHappy": dict(face="happy", mouth_kind="smile", ears=("up", "flopR")),
}
SMALL = {
    "smallHello": dict(small=True),
    "smallCurious": dict(small=True, mouth_kind="o", ears=("perkL", "bentR")),
    "smallOops": dict(small=True, face="wide", mouth_kind="wobble", ears=("flopL", "bentR")),
    "smallDusty": dict(small=True, state="dusty", face="lidded", mouth_kind="flat", ears=("droopL", "droopR")),
}

# ---------- path data -> absolute segments

TOKEN = re.compile(r"[MmLlHhVvCcQqTtAaZz]|-?(?:\d+\.?\d*|\.\d+)(?:e-?\d+)?")

def arc_to_cubics(x1, y1, rx, ry, phi, large, sweep, x2, y2):
    if rx == 0 or ry == 0:
        return [(x2, y2, x2, y2, x2, y2)]
    phi = math.radians(phi)
    cp, sp = math.cos(phi), math.sin(phi)
    dx, dy = (x1 - x2) / 2, (y1 - y2) / 2
    x1p, y1p = cp * dx + sp * dy, -sp * dx + cp * dy
    rx, ry = abs(rx), abs(ry)
    lam = x1p ** 2 / rx ** 2 + y1p ** 2 / ry ** 2
    if lam > 1: rx, ry = rx * math.sqrt(lam), ry * math.sqrt(lam)
    num = rx ** 2 * ry ** 2 - rx ** 2 * y1p ** 2 - ry ** 2 * x1p ** 2
    den = rx ** 2 * y1p ** 2 + ry ** 2 * x1p ** 2
    co = math.sqrt(max(0, num / den)) * (-1 if large == sweep else 1)
    cxp, cyp = co * rx * y1p / ry, -co * ry * x1p / rx
    cx, cy = cp * cxp - sp * cyp + (x1 + x2) / 2, sp * cxp + cp * cyp + (y1 + y2) / 2
    def ang(ux, uy, vx, vy):
        a = math.atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        return a
    t1 = ang(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
    dt = ang((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
    if not sweep and dt > 0: dt -= 2 * math.pi
    if sweep and dt < 0: dt += 2 * math.pi
    n = max(1, math.ceil(abs(dt) / (math.pi / 2)))
    d = dt / n
    k = 4 / 3 * math.tan(d / 4)
    out = []
    for i in range(n):
        a1, a2 = t1 + i * d, t1 + (i + 1) * d
        p1 = (math.cos(a1) - k * math.sin(a1), math.sin(a1) + k * math.cos(a1))
        p2 = (math.cos(a2) + k * math.sin(a2), math.sin(a2) - k * math.cos(a2))
        p3 = (math.cos(a2), math.sin(a2))
        def tr(p): return (cp * rx * p[0] - sp * ry * p[1] + cx, sp * rx * p[0] + cp * ry * p[1] + cy)
        out.append((*tr(p1), *tr(p2), *tr(p3)))
    return out

def parse_path(d):
    toks = TOKEN.findall(d)
    i, cmd = 0, None
    x = y = sx = sy = 0.0
    lastq = None
    segs = []
    def num():
        nonlocal i
        v = float(toks[i]); i += 1; return v
    while i < len(toks):
        if re.match(r"[A-Za-z]", toks[i]):
            cmd = toks[i]; i += 1
            if cmd in "Zz":
                segs.append(("Z",)); x, y = sx, sy; lastq = None; continue
        rel = cmd.islower(); c = cmd.upper()
        ox, oy = (x, y) if rel else (0, 0)
        if c == "M":
            x, y = num() + ox, num() + oy; sx, sy = x, y; segs.append(("M", x, y)); cmd = "l" if rel else "L"; lastq = None
        elif c == "L":
            x, y = num() + ox, num() + oy; segs.append(("L", x, y)); lastq = None
        elif c == "H":
            x = num() + (x if rel else 0); segs.append(("L", x, y)); lastq = None
        elif c == "V":
            y = num() + (y if rel else 0); segs.append(("L", x, y)); lastq = None
        elif c == "Q":
            qx, qy = num() + ox, num() + oy; x, y = num() + ox, num() + oy; segs.append(("Q", qx, qy, x, y)); lastq = (qx, qy)
        elif c == "T":
            qx, qy = (2 * x - lastq[0], 2 * y - lastq[1]) if lastq else (x, y)
            x, y = num() + ox, num() + oy; segs.append(("Q", qx, qy, x, y)); lastq = (qx, qy)
        elif c == "C":
            a, b, cc, dd = num() + ox, num() + oy, num() + ox, num() + oy
            x, y = num() + ox, num() + oy; segs.append(("C", a, b, cc, dd, x, y)); lastq = None
        elif c == "A":
            rx, ry, phi, large, sweep = num(), num(), num(), num(), num()
            nx, ny = num() + ox, num() + oy
            for cub in arc_to_cubics(x, y, rx, ry, phi, int(large), int(sweep), nx, ny):
                segs.append(("C", *cub))
            x, y = nx, ny; lastq = None
        else:
            raise ValueError("unsupported path command " + cmd)
    return segs

def ellipse_segs(cx, cy, rx, ry):
    k = 0.5522847498
    return [("M", cx + rx, cy),
            ("C", cx + rx, cy + k * ry, cx + k * rx, cy + ry, cx, cy + ry),
            ("C", cx - k * rx, cy + ry, cx - rx, cy + k * ry, cx - rx, cy),
            ("C", cx - rx, cy - k * ry, cx - k * rx, cy - ry, cx, cy - ry),
            ("C", cx + k * rx, cy - ry, cx + rx, cy - k * ry, cx + rx, cy), ("Z",)]

def rect_segs(x, y, w, h, r):
    r = min(r, w / 2, h / 2)
    if r <= 0:
        return [("M", x, y), ("L", x + w, y), ("L", x + w, y + h), ("L", x, y + h), ("Z",)]
    k = 0.5522847498 * r
    return [("M", x + r, y), ("L", x + w - r, y), ("C", x + w - r + k, y, x + w, y + r - k, x + w, y + r),
            ("L", x + w, y + h - r), ("C", x + w, y + h - r + k, x + w - r + k, y + h, x + w - r, y + h),
            ("L", x + r, y + h), ("C", x + r - k, y + h, x, y + h - r + k, x, y + h - r),
            ("L", x, y + r), ("C", x, y + r - k, x + r - k, y, x + r, y), ("Z",)]

# ---------- transforms

def mul(a, b):  # a then b?  matrices as (a,b,c,d,e,f): x' = a x + c y + e
    return (a[0] * b[0] + a[2] * b[1], a[1] * b[0] + a[3] * b[1],
            a[0] * b[2] + a[2] * b[3], a[1] * b[2] + a[3] * b[3],
            a[0] * b[4] + a[2] * b[5] + a[4], a[1] * b[4] + a[3] * b[5] + a[5])

I = (1, 0, 0, 1, 0, 0)
def T(x, y): return (1, 0, 0, 1, x, y)
def R(deg): r = math.radians(deg); return (math.cos(r), math.sin(r), -math.sin(r), math.cos(r), 0, 0)
def S(sx, sy): return (sx, 0, 0, sy, 0, 0)

def parse_transform(s):
    m = I
    for name, args in re.findall(r"(\w+)\(([^)]*)\)", s or ""):
        v = [float(t) for t in re.findall(r"-?\d*\.?\d+", args)]
        if name == "translate": m = mul(m, T(v[0], v[1] if len(v) > 1 else 0))
        elif name == "rotate": m = mul(m, R(v[0]))
        elif name == "scale": m = mul(m, S(v[0], v[1] if len(v) > 1 else v[0]))
        elif name == "scaleY": m = mul(m, S(1, v[0]))
    return m

def css_transform(style):
    origin = re.search(r"transform-origin:\s*([-\d.]+)px\s+([-\d.]+)px", style or "")
    tr = re.search(r"transform:\s*([^;]+)", style or "")
    if not tr:
        return I, (tuple(map(float, origin.groups())) if origin else None)
    ox, oy = map(float, origin.groups()) if origin else (0, 0)
    t = tr.group(1).replace("deg", "")
    return mul(mul(T(ox, oy), parse_transform(t)), T(-ox, -oy)), (ox, oy)

def apply(m, x, y): return (m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5])

def bake(segs, m):
    out = []
    for s in segs:
        if s[0] == "Z": out.append(4); continue
        pts = [apply(m, s[i], s[i + 1]) for i in range(1, len(s), 2)]
        out.append({"M": 0, "L": 1, "Q": 2, "C": 3}[s[0]])
        for p in pts: out += [round(p[0], 2), round(p[1], 2)]
    return out

def color(v):
    if v is None or v == "none": return None
    if v.startswith("var("): return "x"            # the page ink: follows light / dark
    if v == "#fff": return "#FFFFFF"
    return v.upper()

ROLES = {"ear-l": "earL", "ear-r": "earR", "eye": "eye", "broom": "broom", "specks": "specks",
         "speck": "speck", "sparkles": "sparkle", "paw-l": "pawL", "paw-r": "pawR"}

def convert(markup):
    root = ET.fromstring(f'<svg xmlns="http://www.w3.org/2000/svg">{markup}</svg>')
    ops, clips, clip_ids = [], [], {}
    def walk(el, m, opacity, role, pivot, clip_stack, extra):
        tag = el.tag.split("}")[-1]
        cls = (el.get("class") or "").split()
        r = next((ROLES[c] for c in cls if c in ROLES), None)
        style = el.get("style") or ""
        if tag == "clipPath":
            shapes = []
            for ch in el:
                shapes += shape_segs(ch, m)
            clip_ids[el.get("id")] = len(clips)
            clips.append(shapes)
            return
        if tag == "g":
            cm, origin = css_transform(style)
            nm = mul(mul(m, parse_transform(el.get("transform"))), cm)
            nrole, npivot = role, pivot
            if r:
                nrole = r
                npivot = apply(m, *origin) if origin else None
                if r == "eye" and not origin:
                    # Blink around the eye's own centre, highlights included.
                    first = next((ch for ch in el if ch.tag.split("}")[-1] == "ellipse"), None)
                    if first is not None:
                        npivot = apply(nm, float(first.get("cx")), float(first.get("cy")))
            ex = dict(extra)
            if r == "speck" or "speck" in cls:
                pass
            ncs = clip_stack
            cp = el.get("clip-path")
            if cp: ncs = clip_stack + [clip_ids[re.search(r"#([^)]+)", cp).group(1)]]
            op = opacity * float(el.get("opacity") or 1)
            for ch in el:
                walk(ch, nm, op, nrole, npivot, ncs, ex)
            return
        segs = shape_segs(el, m)
        if not segs: return
        rr = r or role
        o = {"d": segs, "o": round(opacity * float(el.get("opacity") or 1), 3)}
        f = color(el.get("fill", "#000"))
        if f: o["f"] = f
        s = color(el.get("stroke"))
        if s:
            o["s"] = s
            o["w"] = round(float(el.get("stroke-width") or 1) * math.sqrt(abs(m[0] * m[3] - m[1] * m[2])), 3)
            if el.get("stroke-linecap") == "round": o["cap"] = 1
        if rr: o["r"] = rr
        if rr in ("earL", "earR", "broom", "eye") and pivot: o["p"] = [round(pivot[0], 2), round(pivot[1], 2)]
        if rr == "speck":
            dx = re.search(r"--dx:\s*([-\d.]+)px", style); dy = re.search(r"--dy:\s*([-\d.]+)px", style)
            o["fly"] = [float(dx.group(1)) if dx else 0, float(dy.group(1)) if dy else 0]
        if clip_stack: o["c"] = list(clip_stack)
        ops.append(o)
    def shape_segs(el, m):
        tag = el.tag.split("}")[-1]
        g = lambda k, d=0: float(el.get(k) or d)
        if tag == "path": raw = parse_path(el.get("d"))
        elif tag == "ellipse": raw = ellipse_segs(g("cx"), g("cy"), g("rx"), g("ry"))
        elif tag == "circle": raw = ellipse_segs(g("cx"), g("cy"), g("r"), g("r"))
        elif tag == "rect": raw = rect_segs(g("x"), g("y"), g("width"), g("height"), g("rx"))
        else: return []
        return bake(raw, mul(m, parse_transform(el.get("transform"))))
    for el in root:
        walk(el, I, 1.0, None, None, [], {})
    return {"ops": ops, "clips": clips}

def bounds(art):
    xs, ys = [], []
    for op in art["ops"]:
        d, i = op["d"], 0
        while i < len(d):
            c = d[i]; i += 1
            n = {0: 2, 1: 2, 2: 4, 3: 6, 4: 0}[c]
            for j in range(0, n, 2): xs.append(d[i + j]); ys.append(d[i + j + 1])
            i += n
    return [min(xs), min(ys), max(xs), max(ys)]

if __name__ == "__main__":
    out = {"edge": EDGE, "grip": list(GRIP), "poses": {}, "overlays": {}}
    for k, kw in FULL.items():
        out["poses"][k] = {"kind": "full", **convert(dusty(uid=f"a-{k}", **kw))}
    for k, kw in PEEK.items():
        out["poses"][k] = {"kind": "peek", **convert(dusty(uid=f"a-{k}", peek=True, **kw))}
    for k, kw in SMALL.items():
        out["poses"][k] = {"kind": "small", **convert(dusty(uid=f"a-{k}", **kw))}
    out["overlays"]["broom"] = convert(broom())
    out["overlays"]["specks"] = convert(specks())
    for k, v in out["poses"].items():
        v["bounds"] = [round(b, 1) for b in bounds(v)]
    data = json.dumps(out, separators=(",", ":"))
    # JSON colors contain `"#`, so a one-hash Swift raw string ends at the
    # first color. Pick a delimiter that cannot occur in this data.
    hashes = "#"
    while '"' + hashes in data:
        hashes += "#"
    swift = ("// Generated by design/mascot/export_app.py from dusty.py. Do not edit by hand.\n"
             "// Dusty's poses as flat drawing operations; see Dusty.swift.\n\n"
             "enum DustyArt {\n    static let json = " + hashes + '"' + data + '"' + hashes + "\n}\n")
    open(sys.argv[1], "w").write(swift)
    print("wrote", sys.argv[1], len(data) // 1024, "KB,", len(out["poses"]), "poses")
