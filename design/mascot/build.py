"""Builds index.html, Dusty's character sheet, from the poses in dusty.py.

    python3 dusty.py && python3 build.py
"""
import json

from dusty import CLEAN, DUSTY, INK, dusty

P = json.load(open("parts.json"))


def svg(name, w=None, vb="0 0 240 240", cls="", attrs=""):
    size = f' width="{w}" height="{w}"' if w else ""
    return f'<svg viewBox="{vb}"{size} class="{cls}" {attrs} aria-hidden="true">{P[name]}</svg>'


EXPRESSIONS = [
    ("hello", "Hello", "First run, About, the website", "Dot eyes, ω mouth, one ear up and one flopped. This is Dusty's resting face."),
    ("happy", "Happy", "Scan finished", "Eyes squeezed into arcs, mouth open, sparkles. Celebrates finished work, never a pending choice."),
    ("curious", "Curious", "Find, an empty search", "Head tilted 8°, one ear perked up tall, a small “o” mouth. Used when the app is asking you something."),
    ("sleepy", "Sleepy", "Nothing scanned yet, idle", "Eyes closed with tiny lashes, both ears drooped, a slight squash. Quiet, never sad."),
    ("proud", "Proud", "Space freed, a clean section", "Both ears straight up for the only time. The payoff pose after Cleanup."),
    ("oops", "Oops", "A folder couldn't be read", "Wide eyes, wobbly mouth, one sweat drop. Owns a small problem without alarm."),
]

PALETTE = [
    ("Fluff", CLEAN["fill"], "Body, ears, tail"),
    ("Shade", CLEAN["shade"], "Lower body, cel shadow"),
    ("Light", CLEAN["light"], "Top-left sheen"),
    ("Fur marks", CLEAN["fur"], "ᴗᴗ ticks only"),
    ("Paws", CLEAN["paw"], "Paws and toe pads"),
    ("Inner ear", CLEAN["ear"], "Inside the ears"),
    ("Blush", CLEAN["blush"], "Cheeks, with hatching"),
    ("Nose", CLEAN["nose"], "Nose, tongue"),
    ("Outline", INK, "Every line. Never pure black"),
    ("Accent", "#7966DA", "Sparkles, from the app"),
    ("Dust", DUSTY["fill"], "Before cleanup"),
    ("Dust shade", DUSTY["shade"], "Before cleanup"),
]

ANATOMY = [
    (39, 25, "Ears", "One up, one flopped. The asymmetry is the signature: keep it in every pose except Proud."),
    (50, 36, "Tuft", "A small cowlick between the ears. It's what's left of the dust."),
    (37, 51, "Sheen", "One white stroke, top left. Light always comes from the top left."),
    (59, 55, "Eyes", "Set low and wide, below the middle of the body. Two highlights: big top left, small bottom right."),
    (65, 71, "Blush", "Soft pink oval with three diagonal hatch marks. Never a gradient."),
    (50, 76, "Nose & mouth", "A tiny pink nose over an ω mouth. The mouth stays smaller than one eye."),
    (68, 52, "Fur marks", "Small double ticks (ᴗᴗ), sparse, away from the face. Never zigzags."),
    (80, 73, "Tail", "A puff at the lower right, behind the body."),
    (43, 84, "Paws", "Two lighter paws peeking from the bottom, each with two toe lines."),
]

RULES_DO = [
    "Appear at most once per screen, in quiet places: first run, empty states, a finished scan, after Cleanup.",
    "Keep Dusty small next to content. Dusty frames the moment; the numbers are the message.",
    "Use the grey, dusty version only to show <em>before</em>. Dusty is never grey by default.",
    "Respect Reduce Motion: no breathing, twitching or leaning. Blinks become a still face.",
    "Keep the 3.2 px outline at 240 px and scale it with the art. Below 48 px use the small version.",
]
RULES_DONT = [
    "Nag, guilt or plead. No “Dusty misses you”, no sad faces about full disks.",
    "Appear in a confirmation that removes files (Move to Trash). Serious moments stay plain.",
    "Hold or point at a file as if Dusty chose it. Choices are yours; Dusty just cheers.",
    "Recolour Dusty to match a screen, add clothes, or change the ears' left and right.",
    "Stretch, outline in pure black, or add a drop shadow other than the flat ground shadow.",
]


def paws_svg():
    pal = CLEAN
    out = []
    for x in (17, 49):
        out.append(f'<ellipse cx="{x}" cy="11" rx="11.5" ry="7.6" fill="{pal["paw"]}" stroke="{INK}" stroke-width="2.6"/>'
                   f'<path d="M{x-3},8.5v3.4M{x+3},8.5v3.4" stroke="{pal["fur"]}" stroke-width="1.5" stroke-linecap="round"/>')
    # Same scale as the 150 px peeking Dusty (150 / 240).
    return f'<svg viewBox="0 0 66 22" width="41" height="14" class="peek-paws" aria-hidden="true">{"".join(out)}</svg>'


expr_cards = "".join(f"""
      <figure class="card expr">
        <div class="stage">{svg(k, cls="pose")}</div>
        <figcaption>
          <div class="row"><b>{title}</b><span class="mono">{where}</span></div>
          <p>{note}</p>
        </figcaption>
      </figure>""" for k, title, where, note in EXPRESSIONS)

swatches = "".join(f"""
      <div class="swatch"><i style="background:{hexv}"></i><b>{name}</b><span class="mono">{hexv}</span><small>{use}</small></div>"""
                   for name, hexv, use in PALETTE)

pins = "".join(f'<span class="pin" style="left:{x}%;top:{y}%">{i + 1}</span>' for i, (x, y, *_ ) in enumerate(ANATOMY))
pin_list = "".join(f'<li><span class="num">{i + 1}</span><div><b>{t}</b><p>{d}</p></div></li>' for i, (_, _, t, d) in enumerate(ANATOMY))

sizes = "".join(f'<div class="size">{svg("hello" if px >= 48 else "small", px)}<span class="mono">{px} px</span></div>'
                for px in (160, 96, 64, 40, 24, 16))

html = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Meet Dusty</title>
<meta name="description" content="Dusty, the freedisk.space mascot: character sheet, expressions, palette and rules.">
<style>
:root {{
  --canvas:#F8F7F4; --raised:#FFFFFF; --line:#E4E3DF; --ink:#252B31; --ink2:#66717E; --ink3:#9AA0A8;
  --accent:#7966DA; --accent-soft:rgba(121,102,218,.09); --dusty-ink:{INK}; --stage:#F1EFEA;
  --mono: ui-monospace, "SF Mono", SFMono-Regular, Menlo, monospace;
  color-scheme: light;
}}
@media (prefers-color-scheme: dark) {{
  :root:not([data-theme="light"]) {{
    --canvas:#0B0B0C; --raised:#141416; --line:#26262A; --ink:#F2F2F3; --ink2:#A3A3A8; --ink3:#76767C;
    --accent:#9A8BF0; --accent-soft:rgba(154,139,240,.16); --dusty-ink:#E9E6F5; --stage:#111113; color-scheme: dark;
  }}
}}
:root[data-theme="dark"] {{
  --canvas:#0B0B0C; --raised:#141416; --line:#26262A; --ink:#F2F2F3; --ink2:#A3A3A8; --ink3:#76767C;
  --accent:#9A8BF0; --accent-soft:rgba(154,139,240,.16); --dusty-ink:#E9E6F5; --stage:#111113; color-scheme: dark;
}}
* {{ box-sizing:border-box; }}
html {{ -webkit-text-size-adjust:100%; }}
body {{ margin:0; background:var(--canvas); color:var(--ink); font:15px/1.55 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif; -webkit-font-smoothing:antialiased; transition:background .3s, color .3s; }}
.wrap {{ max-width:1120px; margin:0 auto; padding:0 32px; }}
.mono {{ font-family:var(--mono); font-size:12px; color:var(--ink3); letter-spacing:.01em; }}
.eyebrow {{ font-family:var(--mono); font-size:11px; letter-spacing:.14em; text-transform:uppercase; color:var(--accent); margin:0 0 14px; }}
h1,h2,h3 {{ margin:0; letter-spacing:-.025em; font-weight:650; }}
h2 {{ font-size:34px; line-height:1.1; }}
.lede {{ color:var(--ink2); font-size:17px; max-width:56ch; margin:14px 0 0; }}
section {{ padding:96px 0; border-top:1px solid var(--line); }}
.top {{ display:flex; align-items:center; justify-content:space-between; height:72px; }}
.brand {{ font-weight:700; letter-spacing:-.02em; font-size:17px; }}
.brand span {{ color:var(--accent); }}
.toggle {{ font:500 13px/1 inherit; font-family:inherit; color:var(--ink); background:transparent; border:1px solid var(--line); border-radius:999px; padding:9px 14px; cursor:pointer; }}
.toggle:hover {{ background:var(--accent-soft); }}
.toggle:focus-visible, .btn:focus-visible, .hero-stage:focus-visible, .clean-stage:focus-visible {{ outline:2px solid var(--accent); outline-offset:3px; }}

/* hero */
.hero {{ display:grid; grid-template-columns: 1.05fr 1fr; gap:48px; align-items:center; padding:56px 0 88px; }}
.hero h1 {{ font-size:clamp(56px, 8vw, 104px); line-height:.92; letter-spacing:-.05em; }}
.hero h1 em {{ font-style:normal; color:var(--accent); }}
.hint {{ margin-top:28px; display:flex; gap:10px; flex-wrap:wrap; }}
.chip {{ font-family:var(--mono); font-size:11px; color:var(--ink2); border:1px solid var(--line); border-radius:999px; padding:6px 11px; }}
.hero-stage {{ position:relative; aspect-ratio:1; border-radius:28px; background:
   radial-gradient(60% 55% at 50% 58%, var(--accent-soft), transparent 70%); cursor:pointer; outline:none; }}
.hero-stage svg {{ width:100%; height:100%; overflow:visible; }}
.breathe {{ transform-origin:50% 86%; animation:breathe 3.6s ease-in-out infinite; }}
@keyframes breathe {{ 0%,100% {{ transform:scale(1,1); }} 50% {{ transform:scale(1.012,.985); }} }}
.live .dusty {{ transition:transform .5s cubic-bezier(.2,.8,.2,1); }}
.live .eye {{ transform-box:fill-box; transform-origin:center; transform:translate(var(--ex,0px),var(--ey,0px)) scaleY(var(--blink,1)); transition:transform .12s ease-out; }}
.live .ear-r.twitch {{ animation:twitch .55s ease-out; }}
.live .ear-l.twitch {{ animation:twitchL .55s ease-out; }}
@keyframes twitch {{ 30% {{ transform:rotate(10deg); }} 60% {{ transform:rotate(-4deg); }} 100% {{ transform:rotate(0); }} }}
@keyframes twitchL {{ 30% {{ transform:rotate(-7deg); }} 60% {{ transform:rotate(3deg); }} 100% {{ transform:rotate(0); }} }}
.pop {{ animation:pop .5s cubic-bezier(.3,1.6,.5,1); transform-origin:50% 86%; }}
@keyframes pop {{ 0% {{ transform:scale(1.06,.9); }} 100% {{ transform:scale(1,1); }} }}
.shake {{ animation:shake .8s ease-in-out; transform-origin:50% 86%; }}
@keyframes shake {{ 0%,100% {{ transform:rotate(0); }} 15% {{ transform:rotate(-7deg); }} 30% {{ transform:rotate(7deg); }} 45% {{ transform:rotate(-6deg); }} 60% {{ transform:rotate(5deg); }} 75% {{ transform:rotate(-3deg); }} }}
.sparkles path {{ transform-box:fill-box; transform-origin:center; animation:twinkle 1.6s ease-in-out infinite; }}
.sparkles path:nth-child(2) {{ animation-delay:.4s; }} .sparkles path:nth-child(3) {{ animation-delay:.8s; }} .sparkles path:nth-child(4) {{ animation-delay:1.2s; }}
@keyframes twinkle {{ 0%,100% {{ transform:scale(1); opacity:1; }} 50% {{ transform:scale(.6) rotate(20deg); opacity:.6; }} }}

/* story */
.story {{ display:grid; grid-template-columns:1fr auto 1fr auto 1fr; gap:16px; align-items:center; margin-top:48px; }}
.step {{ text-align:center; }}
.step .stage {{ aspect-ratio:1; }}
.step b {{ display:block; font-size:15px; margin-top:6px; }}
.arrow {{ font-family:var(--mono); color:var(--ink3); font-size:20px; }}
.try {{ margin-top:48px; display:grid; grid-template-columns:320px 1fr; gap:40px; align-items:center; border:1px solid var(--line); border-radius:22px; padding:28px 36px; background:var(--raised); }}
.clean-stage {{ aspect-ratio:1; cursor:pointer; outline:none; border-radius:18px; }}
.clean-stage svg {{ width:100%; height:100%; overflow:visible; }}
.btn {{ font:600 14px/1 -apple-system, BlinkMacSystemFont, sans-serif; color:var(--canvas); background:var(--ink); border:0; border-radius:10px; padding:12px 18px; cursor:pointer; margin-top:20px; }}
.btn:hover {{ opacity:.9; }}
.freed {{ font-family:var(--mono); font-size:13px; color:var(--accent); min-height:20px; margin-top:14px; }}

/* cards */
.grid3 {{ display:grid; grid-template-columns:repeat(3,1fr); gap:20px; margin-top:48px; }}
.card {{ margin:0; border:1px solid var(--line); border-radius:20px; background:var(--raised); overflow:hidden; }}
.stage {{ background:var(--stage); display:grid; place-items:center; }}
.expr .stage {{ aspect-ratio:4/3.2; }}
.expr .stage svg {{ width:78%; height:auto; overflow:visible; }}
.expr figcaption {{ padding:18px 20px 20px; }}
.expr .row {{ display:flex; justify-content:space-between; align-items:baseline; gap:12px; }}
.expr .row .mono {{ text-align:right; }}
.expr p {{ margin:8px 0 0; color:var(--ink2); font-size:14px; }}

/* anatomy */
.anatomy {{ display:grid; grid-template-columns:1fr 1fr; gap:56px; margin-top:48px; align-items:start; }}
.anat-stage {{ position:relative; aspect-ratio:1; border-radius:24px; background:var(--stage); }}
.anat-stage svg {{ width:100%; height:100%; }}
.pin {{ position:absolute; width:24px; height:24px; margin:-12px 0 0 -12px; border-radius:50%; background:var(--accent); color:#fff; font:600 11px/24px var(--mono); text-align:center; box-shadow:0 0 0 3px var(--stage); }}
.anat-list {{ list-style:none; margin:0; padding:0; }}
.anat-list li {{ display:grid; grid-template-columns:28px 1fr; gap:12px; padding:13px 0; border-bottom:1px solid var(--line); }}
.anat-list li:first-child {{ padding-top:0; }}
.anat-list .num {{ font:600 12px/22px var(--mono); color:var(--accent); }}
.anat-list b {{ font-size:15px; }}
.anat-list p {{ margin:2px 0 0; color:var(--ink2); font-size:14px; }}
.proportions {{ display:grid; grid-template-columns:repeat(4,1fr); gap:0; margin-top:40px; border-top:1px solid var(--line); }}
.proportions div {{ padding:18px 18px 0 0; }}
.proportions b {{ display:block; font:600 22px/1.2 -apple-system, sans-serif; letter-spacing:-.02em; }}

/* light/dark */
.modes {{ display:grid; grid-template-columns:1fr 1fr; margin-top:48px; border-radius:24px; overflow:hidden; border:1px solid var(--line); }}
.mode {{ padding:28px; aspect-ratio:1.2; display:grid; grid-template-rows:auto 1fr; }}
.mode svg {{ width:72%; margin:auto; overflow:visible; }}
.mode.l {{ background:#F8F7F4; color:#252B31; --dusty-ink:{INK}; }}
.mode.d {{ background:#0B0B0C; color:#F2F2F3; --dusty-ink:#E9E6F5; }}
.mode .mono {{ color:inherit; opacity:.55; }}

/* sizes */
.sizes {{ display:flex; align-items:flex-end; gap:40px; flex-wrap:wrap; margin-top:48px; padding:36px; border:1px solid var(--line); border-radius:22px; background:var(--raised); }}
.size {{ display:flex; flex-direction:column; align-items:center; gap:12px; }}
.size svg {{ overflow:visible; }}
.silhouette {{ display:flex; gap:40px; align-items:flex-end; margin-left:auto; }}
.silhouette svg {{ filter:brightness(0); opacity:.85; }}
:root[data-theme="dark"] .silhouette svg {{ filter:brightness(0) invert(1); }}
@media (prefers-color-scheme: dark) {{ :root:not([data-theme="light"]) .silhouette svg {{ filter:brightness(0) invert(1); }} }}

/* palette */
.palette {{ display:grid; grid-template-columns:repeat(6,1fr); gap:24px 20px; margin-top:48px; }}
.swatch i {{ display:block; aspect-ratio:1.4; border-radius:14px; border:1px solid var(--line); margin-bottom:10px; }}
.swatch b {{ display:block; font-size:14px; }}
.swatch .mono {{ display:block; text-transform:uppercase; }}
.swatch small {{ display:block; color:var(--ink2); font-size:12.5px; margin-top:2px; }}

/* in the app */
.apps {{ display:grid; grid-template-columns:1.1fr 1fr; gap:20px; margin-top:48px; }}
.app {{ border:1px solid var(--line); border-radius:20px; background:var(--raised); padding:28px; position:relative; }}
.app .label {{ position:absolute; top:16px; right:18px; }}
.empty {{ display:flex; flex-direction:column; align-items:center; text-align:center; padding:28px 0 12px; }}
.empty svg {{ width:120px; height:120px; overflow:visible; }}
.empty b {{ font-size:15px; margin-top:6px; }}
.empty p {{ color:var(--ink2); font-size:13px; margin:4px 0 0; max-width:34ch; }}
.empty a {{ color:var(--accent); font-size:13px; font-weight:500; margin-top:12px; text-decoration:none; }}
.stack {{ display:flex; flex-direction:column; gap:20px; }}
.toast {{ display:inline-flex; align-items:center; gap:12px; border:1px solid var(--line); border-radius:999px; padding:6px 18px 6px 8px; background:var(--canvas); box-shadow:0 8px 28px rgba(0,0,0,.08); font-size:13px; margin-top:26px; }}
.toast svg {{ width:34px; height:34px; overflow:visible; }}
.toast .mono {{ color:var(--ink2); }}
.toast a {{ color:var(--accent); font-weight:500; text-decoration:none; }}
.peek-wrap {{ position:relative; padding-top:101px; }}
.peek-wrap .peeker {{ position:absolute; left:50%; top:0; width:150px; margin-left:-75px; height:101px; overflow:hidden; }}
.peek-wrap .peeker svg {{ width:150px; height:150px; margin-top:-6px; }}
.peek-paws {{ position:absolute; left:50%; top:94px; margin-left:-20.5px; z-index:2; }}
.sheet {{ position:relative; z-index:1; border:1px solid var(--line); border-radius:16px; background:var(--canvas); padding:18px 20px; }}
.sheet b {{ font-size:15px; }}
.sheet .mono {{ display:block; margin-top:4px; }}
.sheet .row {{ display:flex; justify-content:space-between; align-items:center; margin-top:14px; padding-top:12px; border-top:1px solid var(--line); font-size:13px; color:var(--ink2); }}
.sheet .row a {{ color:var(--accent); font-weight:500; text-decoration:none; }}

/* rules */
.rules {{ display:grid; grid-template-columns:1fr 1fr; gap:20px; margin-top:48px; }}
.rules ul {{ list-style:none; margin:14px 0 0; padding:0; }}
.rules li {{ padding:12px 0 12px 30px; border-bottom:1px solid var(--line); color:var(--ink2); font-size:14.5px; position:relative; }}
.rules li::before {{ position:absolute; left:2px; top:11px; font-weight:700; }}
.rules .do li::before {{ content:"✓"; color:#3E8E63; }}
.rules .dont li::before {{ content:"×"; color:#C2453D; font-size:18px; top:8px; }}
.rules h3 {{ font-size:18px; }}
.rules em {{ font-style:normal; color:var(--ink); }}
footer {{ padding:48px 0 72px; border-top:1px solid var(--line); display:flex; justify-content:space-between; gap:16px; flex-wrap:wrap; }}

@media (max-width: 900px) {{
  .hero, .anatomy, .apps, .rules, .try {{ grid-template-columns:1fr; }}
  .grid3 {{ grid-template-columns:1fr 1fr; }}
  .palette {{ grid-template-columns:repeat(3,1fr); }}
  .proportions {{ grid-template-columns:1fr 1fr; }}
  .silhouette {{ margin-left:0; }}
  .try {{ padding:24px; }} .try .clean-stage {{ max-width:300px; }}
}}
@media (max-width: 560px) {{
  .wrap {{ padding:0 16px; }}
  section {{ padding:64px 0; }}
  h2 {{ font-size:28px; }}
  .grid3 {{ grid-template-columns:1fr; }}
  .story {{ grid-template-columns:1fr; }} .arrow {{ transform:rotate(90deg); justify-self:center; }}
  .modes {{ grid-template-columns:1fr; }}
  .palette {{ grid-template-columns:1fr 1fr; }}
  .sizes {{ gap:24px; padding:24px; }}
}}
@media (prefers-reduced-motion: reduce) {{
  .breathe, .sparkles path, .pop, .shake, .twitch {{ animation:none !important; }}
  .live .dusty, .live .eye {{ transition:none; }}
}}
</style>
</head>
<body>
<div class="wrap">
  <header class="top">
    <div class="brand">freedisk<span>.space</span> <span class="mono" style="margin-left:10px">Mascot · v1</span></div>
    <button class="toggle" id="theme" type="button">Dark</button>
  </header>

  <div class="hero">
    <div>
      <p class="eyebrow">Meet the mascot</p>
      <h1>Hi, I'm <em>Dusty.</em></h1>
      <p class="lede">A dust bunny: the little clump of fluff that gathers in forgotten corners. Dusty lives in the quiet parts of freedisk.space, and is a lot happier with a bit of room.</p>
      <div class="hint"><span class="chip">Move your cursor</span><span class="chip">Click Dusty</span><span class="chip">Wait a moment</span></div>
    </div>
    <div class="hero-stage" id="hero" tabindex="0" role="img" aria-label="Dusty, a lavender dust bunny with one ear up and one ear flopped, smiling.">
      <div class="breathe" style="width:100%;height:100%">{svg("hello", cls="live")}</div>
    </div>
  </div>
</div>

<section>
  <div class="wrap">
    <p class="eyebrow">01 · The story</p>
    <h2>Dusty starts out dusty.</h2>
    <p class="lede">On a full disk Dusty is grey, clumpy and a little grumpy. A good cleanup shakes the dust loose, and the lavender underneath comes back. The before-and-after is the whole brand in one character.</p>
    <div class="story">
      <div class="step"><div class="stage" style="background:none">{svg("dusty")}</div><b>A full disk</b><span class="mono">grey · clumpy · lint</span></div>
      <div class="arrow">→</div>
      <div class="step"><div class="stage" style="background:none">{svg("shake")}</div><b>Cleanup</b><span class="mono">shake · puff · whoosh</span></div>
      <div class="arrow">→</div>
      <div class="step"><div class="stage" style="background:none">{svg("happy")}</div><b>Room to breathe</b><span class="mono">lavender · fluffy · sparkles</span></div>
    </div>
    <div class="try">
      <div class="clean-stage" id="clean" tabindex="0" role="button" aria-label="Clean Dusty up"></div>
      <div>
        <p class="eyebrow">Try it</p>
        <h3 style="font-size:24px">Give Dusty a cleanup.</h3>
        <p class="lede" style="font-size:15px">Click Dusty or the button. This is how the moment after <span class="mono" style="color:var(--ink)">Move to Trash</span> could feel in the app: one shake, the dust falls away, done.</p>
        <button class="btn" id="cleanBtn" type="button">Clean up Dusty</button>
        <div class="freed" id="freed" aria-live="polite"></div>
      </div>
    </div>
  </div>
</section>

<section>
  <div class="wrap">
    <p class="eyebrow">02 · Expressions</p>
    <h2>Six moods, each with a job.</h2>
    <p class="lede">Every expression belongs to a moment in the app. Dusty never reacts to nothing, and never asks you to do anything.</p>
    <div class="grid3">{expr_cards}
    </div>
  </div>
</section>

<section>
  <div class="wrap">
    <p class="eyebrow">03 · Anatomy</p>
    <h2>Every detail, on purpose.</h2>
    <div class="anatomy">
      <div class="anat-stage">{svg("hello")}{pins}</div>
      <ol class="anat-list">{pin_list}</ol>
    </div>
    <div class="proportions">
      <div><span class="mono">Body</span><b>124 × 108</b><span class="mono">on a 240 grid</span></div>
      <div><span class="mono">Ears</span><b>0.8 × body</b><span class="mono">height, 31 wide</span></div>
      <div><span class="mono">Eyes</span><b>44 apart</b><span class="mono">halfway down the body</span></div>
      <div><span class="mono">Outline</span><b>3.2 / 240</b><span class="mono">round joins</span></div>
    </div>
  </div>
</section>

<section>
  <div class="wrap">
    <p class="eyebrow">04 · Light and dark</p>
    <h2>Same Dusty on both.</h2>
    <p class="lede">The fill is light enough to glow on near-black and the outline is dark enough to hold on paper, so Dusty never changes colour between themes. Only marks drawn on the page (zzz, ?, the ground shadow) follow the theme's ink.</p>
    <div class="modes">
      <div class="mode l"><span class="mono">Light · #F8F7F4</span>{svg("sleepy")}</div>
      <div class="mode d"><span class="mono">Dark · #0B0B0C</span>{svg("curious")}</div>
    </div>
  </div>
</section>

<section>
  <div class="wrap">
    <p class="eyebrow">05 · Sizes</p>
    <h2>Readable from a poster to the menu bar.</h2>
    <p class="lede">At 48 px and below, use the small version: 13 big bumps instead of 24, no fur marks and no sheen. The silhouette alone still reads as a bunny.</p>
    <div class="sizes">{sizes}
      <div class="silhouette">{svg("hello", 64)}{svg("small", 24)}</div>
    </div>
  </div>
</section>

<section>
  <div class="wrap">
    <p class="eyebrow">06 · Colour</p>
    <h2>Lavender, from the app's violet.</h2>
    <p class="lede">Dusty's fluff is the app accent <span class="mono" style="color:var(--ink)">#7966DA</span> mixed with paper. Pink appears only on the nose, inner ears and cheeks. The outline is a violet-tinted ink, never pure black.</p>
    <div class="palette">{swatches}
    </div>
  </div>
</section>

<section>
  <div class="wrap">
    <p class="eyebrow">07 · In the app</p>
    <h2>Small, calm and only when it helps.</h2>
    <div class="apps">
      <div class="app">
        <span class="label mono">Empty state</span>
        <div class="empty">
          {svg("proud")}
          <b>Nothing left to review</b>
          <p>Every cache in this scan is in Cleanup or already gone.</p>
          <a href="#" onclick="return false">Open Cleanup →</a>
        </div>
      </div>
      <div class="stack">
        <div class="app">
          <span class="label mono">Toast</span>
          <div class="toast">{svg("small")}<span>Scan complete</span><span class="mono">2.25M items · 8.0 s</span><a href="#" onclick="return false">View</a></div>
        </div>
        <div class="app">
          <span class="label mono">After Cleanup</span>
          <div class="peek-wrap">
            <div class="peeker">{svg("hello")}</div>
            {paws_svg()}
            <div class="sheet">
              <b>3 items moved to the Trash</b>
              <span class="mono">2.07 GB freed when you empty the Trash</span>
              <div class="row"><span>Changed your mind?</span><a href="#" onclick="return false">Put Back</a></div>
            </div>
          </div>
        </div>
      </div>
    </div>
  </div>
</section>

<section>
  <div class="wrap">
    <p class="eyebrow">08 · Rules</p>
    <h2>A mascot that never nags.</h2>
    <p class="lede">Some mascots guilt you into coming back. Dusty is the opposite: calm, rare and on your side. Your files and your choices always come first.</p>
    <div class="rules">
      <div class="do"><h3>Do</h3><ul>{"".join(f"<li>{r}</li>" for r in RULES_DO)}</ul></div>
      <div class="dont"><h3>Don't</h3><ul>{"".join(f"<li>{r}</li>" for r in RULES_DONT)}</ul></div>
    </div>
  </div>
</section>

<div class="wrap">
  <footer><span class="mono">Dusty · freedisk.space · drawn in SVG, every pose generated from one set of shapes</span><span class="mono">design/mascot/dusty.py</span></footer>
</div>

<script>
const POSES = {json.dumps({k: P[k] for k in ("hello", "happy", "dusty", "shake")})};
const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;

// theme toggle
const root = document.documentElement, tbtn = document.getElementById('theme');
function isDark() {{ return root.dataset.theme ? root.dataset.theme === 'dark' : matchMedia('(prefers-color-scheme: dark)').matches; }}
function label() {{ tbtn.textContent = isDark() ? 'Light' : 'Dark'; }}
try {{ const t = new URLSearchParams(location.search).get('theme') || localStorage.getItem('dusty-theme'); if (t) root.dataset.theme = t; }} catch (e) {{}}
label();
tbtn.onclick = () => {{ root.dataset.theme = isDark() ? 'light' : 'dark'; try {{ localStorage.setItem('dusty-theme', root.dataset.theme); }} catch (e) {{}} label(); }};

// hero: eyes follow, lean, blink, twitch, click for joy
const hero = document.getElementById('hero');
let svgEl = hero.querySelector('svg'), busy = false;
function setPose(name) {{
  svgEl.innerHTML = POSES[name];
}}
function look(x, y) {{
  if (busy) return;
  const r = hero.getBoundingClientRect();
  const dx = (x - (r.left + r.width / 2)) / (r.width / 2), dy = (y - (r.top + r.height * .58)) / (r.height / 2);
  const clamp = (v, m) => Math.max(-m, Math.min(m, v));
  svgEl.style.setProperty('--ex', clamp(dx * 3.4, 3.4) + 'px');
  svgEl.style.setProperty('--ey', clamp(dy * 3, 2.8) + 'px');
  const body = svgEl.querySelector('.dusty');
  if (body && !reduce) body.style.transform = `rotate(${{clamp(dx * 4, 5)}}deg)`;
}}
addEventListener('pointermove', e => look(e.clientX, e.clientY), {{ passive: true }});
function blink() {{
  if (!busy) {{ svgEl.style.setProperty('--blink', .08); setTimeout(() => svgEl.style.setProperty('--blink', 1), 130); }}
  setTimeout(blink, 2200 + Math.random() * 3200);
}}
function twitch() {{
  const ear = svgEl.querySelector(Math.random() < .7 ? '.ear-r' : '.ear-l');
  if (ear && !busy) {{ ear.classList.remove('twitch'); void ear.getBBox(); ear.classList.add('twitch'); }}
  setTimeout(twitch, 3800 + Math.random() * 4200);
}}
if (!reduce) {{ setTimeout(blink, 1600); setTimeout(twitch, 2600); }}
function joy() {{
  if (busy) return; busy = true;
  setPose('happy'); svgEl.classList.remove('pop'); void svgEl.getBBox(); if (!reduce) svgEl.classList.add('pop');
  setTimeout(() => {{ setPose('hello'); svgEl.classList.remove('pop'); busy = false; }}, 1500);
}}
hero.addEventListener('click', joy);
hero.addEventListener('keydown', e => {{ if (e.key === 'Enter' || e.key === ' ') {{ e.preventDefault(); joy(); }} }});

// cleanup demo
const stage = document.getElementById('clean'), btn = document.getElementById('cleanBtn'), freed = document.getElementById('freed');
let state = 'dusty';
function draw(name, cls) {{
  stage.innerHTML = `<svg viewBox="0 0 240 240" class="${{cls || ''}}" aria-hidden="true">${{POSES[name]}}</svg>`;
}}
draw('dusty');
function clean() {{
  if (state === 'busy') return;
  if (state === 'clean') {{ state = 'dusty'; draw('dusty'); btn.textContent = 'Clean up Dusty'; freed.textContent = ''; return; }}
  state = 'busy';
  draw('shake', reduce ? '' : 'shake');
  setTimeout(() => {{
    draw('happy', reduce ? '' : 'pop');
    freed.textContent = '2.07 GB freed · 3 items in the Trash';
    btn.textContent = 'Make a mess again'; state = 'clean';
  }}, reduce ? 300 : 820);
}}
stage.addEventListener('click', clean); btn.addEventListener('click', clean);
stage.addEventListener('keydown', e => {{ if (e.key === 'Enter' || e.key === ' ') {{ e.preventDefault(); clean(); }} }});
</script>
</body>
</html>
"""

open("index.html", "w").write(html)
print("wrote index.html", len(html) // 1024, "KB")
