"""Build two exploratory freedisk.space logo directions from the Dusty source.

Run from anywhere: python3 design/mascot/logo-concepts/build.py
These are comparison assets; this script does not modify the website or app.
"""

from pathlib import Path
import sys
import xml.etree.ElementTree as ET

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
from dusty import dusty  # noqa: E402

INK = "#252B31"
VIOLET = "#7966DA"
LAVENDER = "#CEC4F7"
OUTLINE = "#2B2440"


def svg(viewbox: str, body: str, label: str) -> str:
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{viewbox}" '
            f'role="img" aria-label="{label}">'
            f'<title>{label}</title>{body}</svg>\n')


def bars(x: float, y: float, unit: float = 1) -> str:
    rows = [(0, 112, 24, INK), (34, 87, 19, "#6D7782"),
            (63, 58, 17, VIOLET)]
    return "".join(
        f'<rect x="{x}" y="{y + top * unit}" width="{width * unit}" '
        f'height="{height * unit}" rx="{8 * unit}" fill="{color}"/>'
        for top, width, height, color in rows
    )


def wordmark(x: int, baseline: int = 122) -> str:
    # One text run lets the browser place the period immediately after the k.
    # Fixed x offsets made the two runs overlap at compact header sizes.
    common = (f'y="{baseline}" font-family="-apple-system, BlinkMacSystemFont, '
              'Helvetica Neue, Arial, sans-serif" font-size="76" '
              'font-weight="760" letter-spacing="-3.6"')
    return (f'<text x="{x}" {common}>'
            f'<tspan fill="{INK}">freedisk</tspan>'
            f'<tspan fill="{VIOLET}">.space</tspan></text>')


def peek_symbol() -> str:
    # The top bar is Dusty's ledge. Its body is clipped at the ledge by the
    # original generator, while the two paws remain in front of the bar.
    original = dusty(small=True, peek=True, uid="peek-logo", look=(0, 2.5))
    return (bars(5, 77, .75)
            + f'<g transform="translate(-12 0) scale(.45)">{original}</g>')


def silhouette_symbol() -> str:
    # One upright left ear and one right ear that folds outwards are Dusty's
    # defining silhouette. Three cutouts make the cleared-stack cue part of
    # the body rather than a separate badge.
    return f'''
      <rect x="6" y="7" width="136" height="136" rx="30" fill="{INK}"/>
      <path d="M48 65 C37 53 36 36 40 23 C42 16 49 17 54 24
               C62 36 62 49 65 61 Z" fill="{LAVENDER}"
            stroke="{OUTLINE}" stroke-width="3" stroke-linejoin="round"/>
      <path d="M91 64 C94 42 106 32 120 38 C129 42 132 51 127 58
               C121 64 112 58 105 67 Z" fill="{LAVENDER}"
            stroke="{OUTLINE}" stroke-width="3" stroke-linejoin="round"/>
      <path d="M45 35 C46 29 48 26 50 31 C54 38 53 45 55 51"
            fill="none" stroke="#F6C4DA" stroke-width="7" stroke-linecap="round"/>
      <path d="M106 51 C113 43 121 45 124 51" fill="none"
            stroke="#F6C4DA" stroke-width="6" stroke-linecap="round"/>
      <path d="M82 56 C86 55 88 59 89 61 C104 61 114 69 118 80
               C127 85 126 93 121 98 C126 106 122 113 115 115
               C115 124 107 128 99 125 C94 132 84 131 79 127
               C70 132 61 127 59 121 C50 122 44 116 46 109
               C39 105 39 96 43 91 C39 85 44 77 50 76
               C53 67 63 62 73 62 C75 57 78 56 82 56 Z"
            fill="{LAVENDER}" stroke="{OUTLINE}" stroke-width="3.5"
            stroke-linejoin="round"/>
      <path d="M51 97 H93 M51 108 H82 M51 119 H70" fill="none"
            stroke="{INK}" stroke-width="6" stroke-linecap="round"/>
      <circle cx="77" cy="83" r="3.7" fill="{OUTLINE}"/>
      <circle cx="101" cy="83" r="3.7" fill="{OUTLINE}"/>
      <path d="M87 91 Q89 94 91 91" fill="none" stroke="{OUTLINE}"
            stroke-width="2.5" stroke-linecap="round"/>
    '''


def compact_symbol() -> str:
    # Distilled favicon: the same ear orientation and three clear stripes,
    # with small facial marks omitted at 16–48 px.
    return f'''
      <rect width="128" height="128" rx="29" fill="{INK}"/>
      <path d="M38 58 C29 46 30 25 37 15 C41 12 47 19 50 26
               C54 36 53 48 55 54 Z M75 57 C79 39 90 29 103 35
               C110 39 114 48 107 52 C101 56 91 51 88 62 Z"
            fill="{LAVENDER}" stroke="{OUTLINE}" stroke-width="2.5"/>
      <path d="M70 51 C76 50 79 54 80 56 C99 56 111 66 112 79
               C118 86 114 94 109 98 C109 110 99 116 87 113
               C77 121 68 115 64 114 C51 119 43 110 42 105
               C32 101 31 89 37 82 C32 70 44 58 60 57
               C62 53 65 51 70 51 Z"
            fill="{LAVENDER}" stroke="{OUTLINE}" stroke-width="3"/>
      <path d="M44 85 H84 M44 97 H72 M44 109 H61" fill="none"
            stroke="{INK}" stroke-width="5.5" stroke-linecap="round"/>
    '''


def write(name: str, content: str) -> None:
    ET.fromstring(content)
    (HERE / name).write_text(content, encoding="utf-8")


def main() -> None:
    write("01-dusty-peek-mark.svg",
          svg("0 0 95 144", peek_symbol(), "Dusty peeking over the freedisk stack"))
    write("01-dusty-peek-wordmark.svg",
          svg("0 0 600 144", peek_symbol() + wordmark(118),
              "freedisk.space with Dusty peeking over the stack"))
    write("02-dusty-clearspace-mark.svg",
          svg("0 0 148 151", silhouette_symbol(),
              "Dusty silhouette with three clear-space lines"))
    write("02-dusty-clearspace-wordmark.svg",
          svg("0 0 758 151", silhouette_symbol() + wordmark(163),
              "freedisk.space with the Dusty clear-space mark"))
    write("02-dusty-clearspace-small.svg",
          svg("0 0 128 128", compact_symbol(),
              "Simplified Dusty clear-space app icon"))

    board = f'''
      <rect width="900" height="720" rx="32" fill="#F7F6F4"/>
      <text x="44" y="61" fill="{INK}" font-size="28" font-weight="700"
            font-family="-apple-system,Helvetica Neue,Arial">Two Dusty logo directions</text>
      <text x="44" y="92" fill="#6D7782" font-size="15"
            font-family="-apple-system,Helvetica Neue,Arial">Explorations only · current live logo stays as it is</text>
      <rect x="32" y="120" width="836" height="244" rx="24" fill="white" stroke="#E1E3E8"/>
      <text x="55" y="160" fill="{VIOLET}" font-size="15" font-weight="700"
            font-family="-apple-system,Helvetica Neue,Arial">01 / PEEK THROUGH THE STACK</text>
      <g transform="translate(60 183) scale(.91)">{peek_symbol()}{wordmark(118)}</g>
      <text x="60" y="335" fill="#6D7782" font-size="14"
            font-family="-apple-system,Helvetica Neue,Arial">Expressive wordmark for the site and larger placements</text>
      <rect x="32" y="385" width="836" height="287" rx="24" fill="white" stroke="#E1E3E8"/>
      <text x="55" y="425" fill="{VIOLET}" font-size="15" font-weight="700"
            font-family="-apple-system,Helvetica Neue,Arial">02 / DUSTY + CLEAR SPACE</text>
      <g transform="translate(60 448) scale(.89)">{silhouette_symbol()}{wordmark(163)}</g>
      <text x="60" y="605" fill="#6D7782" font-size="14"
            font-family="-apple-system,Helvetica Neue,Arial">A compact symbol for the app, dock, and favicon</text>
      <g transform="translate(731 560) scale(.64)">{compact_symbol()}</g>
    '''
    write("compare-both.svg", svg("0 0 900 720", board, "Two freedisk.space Dusty logo concepts"))
    print("Wrote two logo directions and a comparison sheet to", HERE)


if __name__ == "__main__":
    main()
