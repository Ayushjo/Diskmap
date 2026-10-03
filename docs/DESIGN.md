# DiskMap Design System — "Calm"

The complete reference for how DiskMap looks, reads and behaves. Every value
in this document is taken from the code (`Sources/DiskMapApp/DesignSystem.swift`
and `Sources/DiskMapApp/Kit/`); when the code and this file disagree, the code
wins and this file is out of date — fix it in the same change.

Introduced in Milestone 18 (branch `feat/calm-ui`, 2026-10-03). Decision record:
`docs/ARCHITECTURE.md` → "Calm UI: one grammar, one kit".

---

## Contents

1. [Why "calm"](#1-why-calm)
2. [The ten rules](#2-the-ten-rules)
3. [Colour](#3-colour)
4. [Typography](#4-typography)
5. [Space, size and shape](#5-space-size-and-shape)
6. [Lines, surfaces and elevation](#6-lines-surfaces-and-elevation)
7. [Iconography and the brand mark](#7-iconography-and-the-brand-mark)
8. [Buttons](#8-buttons)
9. [Inputs and controls](#9-inputs-and-controls)
10. [Lists and rows](#10-lists-and-rows)
11. [Page anatomy](#11-page-anatomy)
12. [The inspector](#12-the-inspector)
13. [Selection, footers and staging](#13-selection-footers-and-staging)
14. [Data visualisation](#14-data-visualisation)
15. [The shell](#15-the-shell)
16. [Overlays: palette, sheets, popovers, toast](#16-overlays-palette-sheets-popovers-toast)
17. [Page by page](#17-page-by-page)
18. [States: empty, loading, error, locked](#18-states-empty-loading-error-locked)
19. [Motion](#19-motion)
20. [Accessibility](#20-accessibility)
21. [Writing: voice, verbs and formats](#21-writing-voice-verbs-and-formats)
22. [Dark mode and high contrast](#22-dark-mode-and-high-contrast)
23. [Performance rules for views](#23-performance-rules-for-views)
24. [Building a new page — checklist](#24-building-a-new-page--checklist)
25. [Do and don't](#25-do-and-dont)
26. [File map](#26-file-map)
27. [Verifying a change](#27-verifying-a-change)

---

## 1. Why "calm"

DiskMap answers "why is my Mac full, and what can I safely do about it?". Before
the redesign most pages showed too much at once:

- Overview showed free space four times and had four separate "go clean up"
  boxes; File Browser showed the current folder three times.
- Six accent colours; green and black both acted as "the" primary button.
- 15 text sizes; 185 literal corner radii against 8 token uses.
- Ten private inspectors, five copies of a chip, four selection footers,
  three empty-state styles.

The calm system replaces that with **one grammar for every page** and **one
kit** to build it from. The look comes from two references:

| Source | What we took |
|---|---|
| The launch site, `design/website-motion-v1/` | Warm paper `#F8F7F4`, ink `#252B31`, one violet `#7966DA`, the soft treemap with labels inside the tiles, mono eyebrows ("01 / MAP"), generous empty space. |
| designeer.xyz | Near-black dark mode, hairlines instead of boxes, one 13 px text size with two weights, 10 px mono labels and counts, three grey steps, ⌘K chips, flat lists. |

The result should feel quiet: the user's data is the loudest thing on screen.

---

## 2. The ten rules

Checked on every page after every change.

1. **No figure twice on one screen.** Shell + page + inspector count as one
   screen. If the header shows "561.8 MB", the figure strip does not.
2. **At most one primary (ink-filled) button per screen.** Everything else is
   secondary (outline), quiet (text), icon, or link.
3. **One accent.** Violet means selection, focus, links and active chips —
   nothing else.
4. **Safety colours are a dot and a word.** Green / amber / red are never
   fills, never buttons, never backgrounds.
5. **Data colours live only in charts and bars.** Never on text, buttons or
   chrome.
6. **Lines over boxes.** Sections are separated by hairlines and space. A
   bordered box means "a different kind of thing" (a notice, a popover, a
   sheet) — never a default container.
7. **Three visible text sizes per page:** 13 (names, body), 12 (secondary),
   mono figures/labels. Plus at most one 20 pt title and one 28 pt display
   figure.
8. **Same verb everywhere.** "Add to Cleanup", "Reveal in Finder", "Quick
   Look", "Copy Path" (see §21).
9. **Hover reveals row actions; right-click keeps the full menu.** Nothing a
   user needs is hover-only — every hover action also exists in the context
   menu, the inspector and VoiceOver actions.
10. **Removal only through Cleanup.** No page deletes. Staging toasts; the
    Cleanup sheet is the only place anything moves to the Trash, after a
    confirmation (AGENTS.md rule 1).

---

## 3. Colour

All colours are defined in `DiskMapTheme` (`DesignSystem.swift`). Surface and
text colours are **adaptive**: one `NSColor` per token that resolves for
light / dark, and for Increase Contrast when the token defines a
high-contrast value. Never write a literal colour in a view.

### 3.1 Surfaces and text

| Token | Light | Dark | HC light | HC dark | Use |
|---|---|---|---|---|---|
| `canvas` | `#F8F7F4` | `#0B0B0C` | — | — | The one surface: window, sidebar, page, inspector, sheets' body. |
| `raised` | `#FFFFFF` | `#141416` | — | — | Popovers, command palette, toast, search field fill, secondary button fill, the rare card. |
| `line` | `#E4E3DF` | `#26262A` | `#B9B8B3` | `#4A4A50` | Every hairline, outline and track. |
| `ink` | `#252B31` | `#F2F2F3` | — | — | Primary text, primary button fill, display figures. |
| `onInk` | `#FFFFFF` | `#0B0B0C` | — | — | Text and icons on an `ink` fill. |
| `ink2` | `#66717E` | `#A3A3A8` | `#404852` | `#CDCDD2` | Secondary text, inactive nav, idle icons. |
| `ink3` | `#949AA2` | `#76767C` | `#626870` | `#AAAAB0` | Mono labels, tertiary text, column headers, disabled. |
| `accent` | `#7966DA` | `#9A8BF0` | — | — | Selection, focus ring, links, active chip count, checked checkbox. |
| `accentSoft` | accent @ 11% | accent @ 11% | | | Selected row, selected nav item, active chip fill. |
| `hover` | ink @ 4.5% | white @ 4.5% | | | Row hover, quiet/icon button hover, Kbd chip fill. |

Pressed state for quiet, icon and secondary buttons is `ink @ 8%`.

### 3.2 Safety (semantic)

Used **only** as a 6 pt dot followed by a word (`SafetyLabel`), or as the
text colour of a one-line warning. Never as a fill.

| Token | Light | Dark | Word(s) |
|---|---|---|---|
| `safe` | `#3E8E63` | `#6CC495` | Safe, Generally safe, Keeper, Likely forgotten, Pushed |
| `review` | `#B7791F` | `#E0A548` | Review first, Worth reviewing, Unpushed, No lockfile |
| `danger` | `#C2453D` | `#EE7A70` | Protected, Low on space, "Don't move this to the Trash" |

Neutral states (Keep, System, Excluded, No git) use `ink3` for the dot.

### 3.3 The data palette

One palette for every chart, bar, category, file kind and folder colour
(`DiskMapTheme.dataPalette`, `data(_:)`), from the launch site:

| Index | Hex | Name | Typical meaning |
|---|---|---|---|
| 0 | `#849BB8` | slate | Developer / disk images / Dependencies / app bundle |
| 1 | `#A795C7` | violet | Library / virtual disks / Packages / Containers |
| 2 | `#C78797` | rose | Downloads / video / SDKs & simulators |
| 3 | `#7BA89C` | sage | Caches / documents |
| 4 | `#B9A071` | sand | Applications / archives / build output / related data |
| 5 | `#8FACC0` | sky | Documents folder / applications kind |
| 6 | `#A2A4AC` | stone | Other / system / remainder |

Data colours **do not adapt** to dark mode — a tile keeps its identity in
both appearances. Text drawn on a tile uses `tileLabel` (`#252B31`, fixed) at
85% (names) or 60% (sizes).

`wash(color, strength:)` composites a data colour over the light canvas to an
opaque colour; used for nested treemap levels and bubble containers.

### 3.4 Fixed mappings

**File kinds** (`kindColor`): video `#C78797`, disk image `#849BB8`, archive
`#B9A071`, application `#8FACC0`, document `#7BA89C`, virtual disk `#A795C7`,
device backup `#9FB5A9`, database `#A2A4AC`, other → `ink3`. In lists the
kind colour appears only as the 16%-tint behind a `FileIdentityIcon`; the kind
*name* is grey text.

**Age ramp** (`ageColor`, newest → oldest): under 30 d `#7BA89C`, 30–90 d
`#8FACC0`, 90 d–1 y `#B9A071`, 1–2 y `#C99A7E`, over 2 y `#C78797`, unknown
`ink3` @ 50%.

**Forgotten Files ages** (`ForgottenFilesView.ageTint`): 1–2 y `#B9A071`,
2–3 y `#C99A7E`, 3–5 y `#C78797`, 5 y+ `#A795C7`.

**Treemap top-level folders** (`treemapFolderColor`): Library `#A795C7`,
Downloads `#C78797`, Desktop/Documents `#849BB8`, Applications `#B9A071`;
others cycle the data palette by node index. Deeper levels are washed
(−8% per level, floor 65%).

**Storage categories** come from `Sources/DiskMapCore/file-type-categories.json`
(video `#C78797`, audio `#A795C7`, image `#8FACC0`, document `#7BA89C`,
developer `#849BB8`, archive `#B9A071`).

**Developer categories** (`DeveloperStorageView.color(for:)`): dependencies
`data(0)`, caches `data(3)`, build artifacts `data(4)`, containers `data(1)`,
SDKs & simulators `data(2)`, other `data(6)`.

**Safe to Review categories**: caches `data(0)`, build output `data(4)`,
packages `data(1)`, other `data(6)`.

### 3.5 Colour don'ts

- No `Color(red:green:blue:)`, `.blue`, `.orange`, `.gray` in views.
- No second accent (the old blue "info" and purple "developer" are gone).
- No coloured text for sizes or deltas — figures are `ink`; a delta's
  direction is carried by the sign and, in Compare, a small bar.
- No tinted panel backgrounds ("info surface", "review surface").

---

## 4. Typography

System fonts only: **SF Pro** for text, **SF Mono** (`design: .monospaced`)
for figures and labels. Defined in `DiskMapType`; every size is multiplied by
`DiskMapType.scale` (§4.3).

### 4.1 The scale

| Token | Size | Weight | Design | Use |
|---|---|---|---|---|
| `display` | 28 | semibold | text, monospaced digits | The one big figure per page or inspector ("120 GB free", "180 MB"). |
| `title` | 20 | semibold | text | Page title, sheet title. |
| `heading` | 15 | semibold | text | Inspector item name, Explain's lead sentence. |
| `body` | 13 | regular | text | Running text, inactive nav, breadcrumbs. |
| `bodyEmphasis` | 13 | medium | text | Names in lists, button labels, active nav, chip labels, links. |
| `secondary` | 12 | regular | text | Subtitles, row second lines, notes, captions. |
| `figure` | 12 | regular | mono | Sizes in inspectors, summaries, commands, paths in facts. |
| `figureStrong` | 12 | medium | mono | The size column in lists. |
| `figureSmall` | 11 | regular | mono | Dates, counts in chips, secondary columns, meta lines. |
| `label` | 10 | medium | mono, **uppercase, tracking 0.6** | Eyebrows, section labels, column headers, fact labels (`MonoLabel`). |

Two weights do the work: regular and medium. Semibold is reserved for
`display`, `title` and `heading`. Weight modifiers on `secondary`
(`.weight(.medium)` / `.semibold`) exist only where legacy layouts were
migrated; don't add new ones.

### 4.2 Which text goes in mono

Mono: sizes, counts, percentages, dates and ages, durations, paths in
inspector facts, shell commands, keyboard hints, labels/eyebrows.
Not mono: names, sentences, button labels, kind names.

### 4.3 Text size

View ▸ Text Size (and Settings): Smaller 0.9 · Default 1.0 · Larger 1.15 ·
Largest 1.3. Stored under `TextSize` in user defaults. Changing it sets
`DiskMapType.scale` and rebuilds the root view.

Things that scale with it:
- every `DiskMapType` token;
- glyph sizes written as `DiskMapType.scaled(n)`;
- the sidebar width (`212 × max(1, scale)`);
- list columns: `MonoColumn`, `TextColumn`, `ColumnHeaderLabel` widths
  (`× max(1, scale)`) and safety/status label columns (`scaled(n)`), so
  "Generally safe" never truncates at Largest.

Things that do not: hit targets (28 pt controls, 24 pt checkbox area),
hairlines, radii, bar heights.

### 4.4 Text rules

- One line for names (`lineLimit(1)`), truncating in the **middle** for paths
  and file names, at the **tail** for prose.
- Secondary lines are `ink3` in rows, `ink2` elsewhere.
- Sentences in notes and subtitles may wrap
  (`fixedSize(horizontal: false, vertical: true)`); never truncate a warning.

---

## 5. Space, size and shape

### 5.1 Spacing scale (`DiskMapSpace`)

| Token | Value | Typical use |
|---|---|---|
| `xxs` | 4 | Icon-to-text in tight clusters |
| `xs` | 8 | Inline gaps, control clusters |
| `sm` | 12 | Row internal spacing, filter bar gaps |
| `md` | 16 | Group spacing, inspector section gaps |
| `lg` | 24 | Figure strip column padding, between page zones |
| `xl` | 32 | Overview section spacing, empty-state padding |
| `xxl` | 48 | Scanning screen padding |
| `page` | 32 | Reading-column side margin (Overview) |
| `pageTop` | 28 | Space above every page header |
| `row` | 36 | One-line row height |
| `rowTwoLine` | 44 | Two-line row height (name + secondary) |

List pages use **28 pt side padding** for header/filters and **18 pt** around
the list (rows add 10 pt inside, so text lines up at 28).

### 5.2 Fixed metrics (`DiskMapMetric`)

| Metric | Value |
|---|---|
| Top bar height | 44 |
| Sidebar width | 212 × text scale (min 212) |
| Control height (buttons, menus, chips 26) | 28 |
| Search field height | 30 |
| Table header height | 28 |
| Inspector padding | 20 |
| Inspector width | 290 (window < 1450) / 320 (≥ 1450); drawer 280–320 below 1200 |
| Reading width (Overview) | 880 max |
| Selection toolbar height | 48 |
| Review footer hint height | 44 |
| Minimum window | 880 × 600 |

### 5.3 Radius (`DiskMapRadius`)

| Token | Value | Use |
|---|---|---|
| `control` | 6 | Buttons, chips, rows, search field, tiles |
| `card` | 10 | Notices, popovers, chart canvas clip, palette (12) |
| — | 4 | Kbd chip, checkbox, segmented-bar segments (2–3) |
| Capsule | — | Only count badges, toast and proportion bars |

All rounded rectangles use `style: .continuous`.

---

## 6. Lines, surfaces and elevation

- **Hairline** (`Hairline()`): 1 px `line`. Under page headers, between
  header and list, above footers, in inspectors between groups, under
  section labels.
- **Dashed hairline** (`Hairline(dashed: true)`, 3/3): separates the first-run
  hero from its feature hints. Use sparingly — one per screen.
- **Row separators** (`RowSeparator(indent:)`): `line` @ 70%, indented to the
  row's text so icons read as a column.
- **One surface.** Window, sidebar, page and inspector are all `canvas`; they
  are divided by vertical hairlines, never by different fills.
- **Elevation exists only for things that float**:
  - toast: `raised`, hairline, shadow black 8% r10 y3;
  - command palette: `raised`, hairline, radius 12, shadow black 18% r30 y12,
    over a black 25% scrim (35% with Reduce Motion);
  - sheets and popovers: system chrome, `canvas`/`raised` body.
- No shadows on cards, rows, buttons or charts.

---

## 7. Iconography and the brand mark

### 7.1 SF Symbols

| Context | Size | Weight | Colour |
|---|---|---|---|
| Sidebar nav | 11.5 (scaled) | regular | `ink3`, `accent` when selected |
| Search field magnifier | 11.5 | medium | `ink3` |
| Icon buttons | 12.5 | medium | `ink2`, `ink` on hover |
| Row folder glyph | 13–14 | regular | `ink2`, 24 pt frame |
| Chevrons (drill, link rows) | 10 | semibold | `ink3`, `ink2` on hover |
| Empty states | 20 | regular | `ink3` |

Prefer outline symbols (`folder`, `doc`, `eye`) to filled ones.

### 7.2 FileIdentityIcon

The one file icon (`SharedChrome.swift`). A square of the given size, radius
`max(5, size × 0.24)`:
- media files show a Quick Look thumbnail;
- if the thumbnail fails, the **kind glyph** (never a generic white document);
- others show the kind glyph at 44% of the size on the kind colour @ 16%
  (`hover` for "other").

Sizes: 20 (compact lists), 24 (lists), 28 (Cleanup sheet), 40 (inspector).
Applications use the real app icon (`AppIconView`) at 28 / 44.

### 7.3 The mark

The logo's "D" (`Kit/BrandMark.swift`, `DiskMapMark`) is drawn as shapes, so
it stays sharp at every size and follows the appearance. Geometry, in logo
units of a 260 × 273 box:

| Part | Frame | Corners | Fill |
|---|---|---|---|
| Bar | x 0, w 69, full height | 8 | `ink` |
| Top bowl | x 87–260, y 0–129 | TL 8, BL 30, BR 6, TR = 129 (quarter curve) | `accent` |
| Bottom bowl | x 87–260, y 147–273 | TL 34, BL 8, BR = 126, TR 6 | `ink` |

Aspect ratio 260:273. The **wordmark** (`DiskMapWordmark`) is the mark as the
"D" followed by "iskMap" in SF Pro bold at 1.2 × the mark height, 0.1 × height
gap, baselines aligned to the mark's bottom; the sidebar uses a 13 pt mark.

The **app icon** (`Sources/IconRender`, variant 4, default) is the mark at
44% of the canvas on a paper squircle (`#FCFBF8` → `#EFEDE7` vertical
gradient, 6% black hairline), ink `#2B2F35`, violet `#8070F0`, inside the Big
Sur grid (80.5%). The source PNG is in `docs/brand/diskmap-logo.png`. Keep the
two copies of the geometry (`DiskMapMark`, `IconRender.Mark`) in step.

---

## 8. Buttons

All buttons are 28 pt tall, label `bodyEmphasis`, one line, radius 6,
`.continuous`. Disabled lowers opacity; it never changes the layout.

| Style | Look | When | States |
|---|---|---|---|
| `PrimaryButtonStyle(fullWidth:)` | `ink` fill, `onInk` text, 12 pt side padding | The one main action on a screen: Add to Cleanup, Scan This Mac, Save Snapshot, Move to Trash…, Rescan (menu bar) | pressed ink @ 82%; disabled @ 30% |
| `SecondaryButtonStyle(fullWidth:)` | `raised` @ 60% fill, 1 px `line` outline, `ink` text | A labelled action that isn't the main one: Done, Choose Folder…, Search Again, Compare with Previous | pressed ink @ 8%; disabled text @ 35% |
| `QuietButtonStyle(tint:)` | Text only, `ink2` (or tint), 8 pt padding | Toolbar text actions: Cleanup, Save…, Reveal Downloads, Largest items | hover → `ink` text + `hover` fill; pressed ink @ 8%; disabled @ 40% |
| `IconButtonStyle(size:)` | 28 (or 24) pt square, icon only, `ink2` | Reveal, Quick Look, Copy, back/forward, inspector toggle, swap, row hover actions | hover → `ink` + `hover` fill; pressed ink @ 8%; disabled @ 35% |
| `LinkButtonStyle` | `accent` text, no chrome | Navigation in text: Why?, Open in Visualize →, View all, Select generally safe, Put Back | pressed @ 70% |

Rules:
- **One primary per screen**, counting shell + page + inspector + sheet.
  When the inspector holds the primary, the page has none (Applications,
  Snapshots).
- Icon buttons always use a `Label("Name", systemImage:)` so VoiceOver and
  `.help` have a name.
- A done/"In Cleanup" state swaps the primary to secondary with a checkmark;
  clicking it opens the Cleanup sheet.
- Destructive actions are never primary-filled red; "Move to Trash…" is ink
  and always confirms.

---

## 9. Inputs and controls

### 9.1 Search field (`DiskMapSearchField`)

30 pt tall, radius 6, `raised` @ 55% (100% focused), 1 px `line` outline
(`accent` @ 60% focused), magnifier `ink3`, text `body`, clear button when
non-empty, optional `Kbd` shortcut hint inside on the right. Placeholder says
what you can search ("Search by name or path"). Typical max width 260–340.

### 9.2 Menus (`DiskMapMenu`)

Borderless menu showing **label + value** as one text ("Sort" in `ink3`,
"Largest" in `ink`), `chevron.up.chevron.down` 8.5 pt, `bodyEmphasis`, 28 pt
tall. Used for Sort, Size, Where, Age, Color, View. Never a bordered popup.

### 9.3 Chips (`Chip`)

The only chip. 26 pt tall, radius 6, 9 pt side padding, `bodyEmphasis`
label, optional symbol (10.5 pt) and mono count (`figureSmall`).
- Off: `ink2` text, no fill, count `ink3`.
- On: `ink` text, `accentSoft` fill, count `accent`.
- Never truncates (`fixedSize`); rows of chips sit in an `HStack(spacing: 2)`.
- A removable token chip (e.g. "In ~/Movies ×") is an on-chip with `xmark`.

Chips filter; they never navigate.

### 9.4 Tabs (`KitTabs`)

Underline tabs with mono counts, separated by `lg` (24) spacing, each tab
sized to its content. Active: `bodyEmphasis` `ink` + a 1.5 pt `ink`
underline; inactive: `body` `ink2`. A hairline runs under the whole row. Use
tabs for mutually exclusive views of the same data (Forgotten confidence,
Caches safety, Developer table, Compare lists).

A **segmented bar used as tabs** (Safe to Review, Forgotten ages, Developer
categories) shows each segment's dot + name + mono size as the tab, and dims
non-selected segments to 30%.

### 9.5 Keyboard chip (`Kbd`)

`figureSmall` `ink3`, 5 pt padding, 18 pt tall, radius 4, `hover` fill.
Inside the top search field (⌘K), in the palette (esc, ↑↓, ↩).

### 9.6 Checkbox (`KitCheckbox`)

Drawn, not the native checkbox (the native one kept its blue focus ring after
a click, so an unticked box looked coloured):
- 14 pt box (scaled), radius 4, 24 pt hit area;
- off: `raised` fill, 1 px `ink3` @ 70% border;
- on: `accent` fill and border, white 8.5 pt bold checkmark;
- disabled: 35% opacity;
- no focus ring (`focusEffectDisabled`);
- VoiceOver: a toggle with value "checked/unchecked", label "Mark <name>".

Used inside `CheckRow` (§10.4). Settings keeps native toggles.

### 9.7 Multi-select mark (`MultiSelectMark`)

For ⌘-click lists (Find pages, File Browser): a 12 pt
`checkmark.circle.fill` in `accent` when the row is in the multi-selection,
invisible otherwise, 14 pt column.

---

## 10. Lists and rows

### 10.1 KitRow anatomy

```
[leading: mark/checkbox · icon]  Name (bodyEmphasis, ink)            [hover actions] [trailing columns]
                                 secondary line (secondary, ink3)
```

- Height: `rowTwoLine` (44) with a subtitle, `row` (36) without.
- 10 pt horizontal padding, 12 pt between parts; text column min 120 pt.
- Background (`RowBackground`): `accentSoft` when selected or in the
  multi-selection, `hover` on hover, clear otherwise; radius 6.
- Hover shows `RowHoverActions` (Quick Look, Reveal in Finder, Add to
  Cleanup — 24 pt icon buttons) just before the trailing columns, fading in
  over 120 ms.
- Separators: `RowSeparator` indented to the name.

Rows are always a `Button` (select) so VoiceOver and clicks reach them;
double-click opens (folders) or reveals (files).

### 10.2 Columns

| Part | Spec |
|---|---|
| `MonoColumn(text:width:emphasis:)` | Right-aligned mono; `figureStrong` `ink` when emphasised (size), else `figureSmall` `ink2` (dates, %). Width × text scale. |
| `TextColumn(text:width:)` | Left-aligned `secondary` `ink2` (kind, source, location). Width × text scale. |
| `ColumnHeaderLabel(title:alignment:width:)` | `MonoLabel` over the column, same scaled width. |
| Safety column | `SafetyLabel` in a `scaled(96–128)` frame. |
| Proportion column | `ProportionBar` 64–90 pt wide, 3 pt tall. |

Typical widths: kind 92, modified 74, size 74, age 56–64, location 76–84,
status 96–112.

Column order, left to right: name · (kind / location / source) · safety ·
date · bar · **size last**.

### 10.3 Relative ages (`RelativeAge`)

One format everywhere:
- `short(day:)` / `short(ageDays:)` for columns: Today, Yesterday, "3 d",
  "4 mo", "2 y", "—" when unknown;
- `long(day:)` for inspectors and VoiceOver: "3 days ago", "1 month ago",
  "2 years ago", "Unknown".

Forgotten Files' column uses `ForgottenAgeFormat.short` ("8 mo", "3 y",
"Very old" beyond 15 y).

### 10.4 Checkbox rows (`CheckRow`)

For review lists where ticking and inspecting are different actions (Clean
pages, Duplicates, Developer Items / By tool, Applications, Age Map):

```swift
CheckRow {
    KitCheckbox(isOn: binding, label: "Mark \(name)")
    Button { inspect } label: { KitRow(...) }
}
```

`CheckRow` adds 8 pt leading padding and tells the row (environment
`kitRowLeadingInset` = 34) to draw its highlight back under the checkbox, so
checkbox, icon and name read as one row. Gap checkbox → row 2 pt, plus the
row's 10 pt padding.

### 10.5 Selection models

| Pattern | Pages | How |
|---|---|---|
| ⌘-click / ⇧-click multi-select | Biggest Files, Biggest Folders, Find, Forgotten Files, File Browser | `model.select(id, ordered:)`; `MultiSelectMark`; `NodeSelectionToolbar` or a page toolbar when > 1 selected |
| Checkboxes | Safe to Review, Caches, Old Downloads, Large Media, Duplicates, Developer Storage, Applications, Age Map | `CheckRow` + `ReviewFooter` |
| Single selection only | Overview link rows, Visualize largest items, Snapshots | — |

The inspected row (the one the inspector shows) and ticked rows are
independent: ticking doesn't change the inspector; clicking a row does.

### 10.6 Keyboard (`.listKeyboard`)

Every list: ↑/↓ (or j/k) move, Return opens, Space quick-looks, ⌘⌫ adds to
Cleanup, ⌘A selects all, Esc clears. File Browser: Return opens a folder,
⌘[ / ⌘] back/forward, ⇧⌘I inspector. Keep this modifier on every new list.

---

## 11. Page anatomy

Every list page, top to bottom:

```
  EYEBROW                                              (mono summary)
  Title                                                 or one action
  One-line subtitle
  ─────────────────────────────────────────────────────────────────── (optional)
  [Figure strip: LABEL / value / detail | LABEL / value | …]
  [Stacked bar → tabs or chips]
  [Search field]  [chips]                         [Sort ▾] [other ▾]
  ═══════════════════════════════════════════════════════════════════ hairline
  NAME                               KIND      MODIFIED       SIZE
  rows…
  ═══════════════════════════════════════════════════════════════════
  footer: hint + link, or the selection toolbar
```

Header block padding: 28 sides, `pageTop` (28) top, 12 bottom, 18 pt
between parts.

### 11.1 PageHeader

`PageHeader(eyebrow:title:subtitle:trailing:)`:
- eyebrow: `MonoLabel` naming the section ("FIND", "CLEAN", "EXPLORE",
  "EXPLORE · FILE BROWSER");
- title: `title` `ink`;
- subtitle: one sentence, `secondary` `ink2`;
- trailing, bottom-aligned: a `HeaderSummary` (mono parts joined by "  ·  ",
  e.g. "21 files · 561.8 MB") **or** a single action (Save Snapshot, Search
  Again, Reveal Downloads) — not both.

### 11.2 FigureStrip

2–4 inline figures, each a `MonoLabel` above a 20 pt semibold
monospaced-digit value and an optional `secondary` detail, separated by 1 px
vertical hairlines, 24 pt padding either side. Replaces stat cards. Don't
repeat a figure the header already shows.

### 11.3 SectionHeader

`SectionHeader(label:detail:trailing:)`: `MonoLabel` in `ink2`, optional mono
detail in `ink3` ("~243.7 MB", "3 items · 12 MB"), an optional trailing link,
then a hairline. Used for groups inside a page (Overview sections, Duplicates
groups, Developer By-tool groups, Find's start page).

### 11.4 Notice (`DiskMapNoticeBanner`)

A slim bordered row (radius 10, 1 px `line`, 12/10 padding): small icon, a
`bodyEmphasis` title, a `secondary` sentence, optional mono examples, optional
link action. One per page at most — combine conditions into one notice
(Developer Storage: stale projects + no lockfile).

### 11.5 Filter row

Search first (fixed max width), then chips, `Spacer`, then menus on the
right. If there's no room, chips move to their own row below (Applications,
Large Media, Old Downloads).

---

## 12. The inspector

The right column (`AdaptiveInspectorSplit`): `canvas`, 1 px hairline on its
leading edge, 290/320 pt. Below a 1200 pt window it becomes a drawer opened
by an "Inspector" button, over a black 12% scrim.

Contents (`InspectorColumn`, 20 pt padding, 18 pt spacing), top to bottom:

1. **Header** (`InspectorHeader`): 40 pt icon (or a preview), name in
   `heading`, size in `display`, one mono detail line ("Video · <0.1% of used
   space").
2. Hairline.
3. **Facts** (`FactRow`): `MonoLabel` over a mono value that wraps (Location,
   Modified, Project, Rebuild, Contents…).
4. Optional groups: composition (stacked bar + top 5 rows), largest files (5
   rows + "View all"), related files, recipe command.
5. Hairline.
6. **Note** (`Note(label:text:)`): one sentence, no box ("Why it's large",
   "What it is", "If you remove it", "Why it was flagged").
7. **Safety line** (`SafetyLine`): `SafetyLabel` + one sentence of reason and
   consequence.
8. **Actions** (`InspectorActions`): one full-width primary ("Add to Cleanup",
   or secondary "In Cleanup ✓" when staged); a row of icon buttons (Reveal in
   Finder, Quick Look, Copy Path); an overflow `…` menu for navigation (Show
   in Visualize, Show in File Browser, Open in File Browser, Biggest Files in
   This Folder).

Variants share these parts:

| Inspector | Where | Extras |
|---|---|---|
| `FileInspector` | Biggest Files, Find, Forgotten, Duplicates, Old Downloads, Large Media, File Browser, Visualize | `extraFacts`, `note`, `allowStage`, `preview` (Large Media thumbnail) |
| `FolderInspector` | Biggest Folders, Find, File Browser, Visualize, Developer By tool | Built off the main thread; "Made of" bar + top 5; largest files; reviewable note |
| `ReviewableInspector` | Safe to Review, Caches | Locations list; "Generally safe to clear" label |
| `DeveloperInspector` | Developer Storage | Git block, rebuild cost, recipe as a mono command with copy; primary disabled ("Use the command above") when Trash is unsafe |
| App inspector | Applications | App icon, size bar (bundle vs related data), related files, removal guidance |
| Snapshot / Change inspectors | Snapshots | Capture facts; before/after/change facts |

Empty inspector: `DiskMapEmptyState` with a symbol and "Select a …" + "Its
details and actions appear here."

The inspector **never repeats** the current folder or page summary; File
Browser shows only the selected row.

---

## 13. Selection, footers and staging

### 13.1 SelectionToolbar

48 pt bar above the bottom edge, hairline on top:
`N selected` (`bodyEmphasis`) · mono bytes · **Clear** (quiet) · spacer · Reveal
and Copy (icon buttons) · **Add to Cleanup** (primary).

### 13.2 ReviewFooter

For checkbox lists. With nothing ticked: a 44 pt row with a `secondary`
`ink3` hint and a quick-select link ("Tick items to clean, or Select generally
safe", "Select all shown", "Select not recently used", "Select extra
copies"). With something ticked: the `SelectionToolbar`.

### 13.3 Staging feedback

- Adding to Cleanup **always** shows a toast and **never** opens the Cleanup
  sheet: "Added to Cleanup — ⇧⌘⌫ to review", "Added 3 files to Cleanup —
  ⇧⌘⌫ to review", "Already in Cleanup", "Blocked by safety rules".
- The top bar's Cleanup button shows a mono count badge (`accent` capsule,
  `onInk` text).
- Items that may not be staged (protected paths, Trash-unsafe tool data,
  excluded Forgotten files, the last copy of a duplicate) have their
  checkbox disabled, no hover "Add to Cleanup", and a disabled primary.

---

## 14. Data visualisation

### 14.1 Bars

| Component | Height | Track | Use |
|---|---|---|---|
| `ProportionBar(fraction:tint:height:)` | 3 (default), 2 (sidebar, menu bar), 6 (capacity, Compare) | `line` capsule | One value against a whole (category row, folder share, disk used). Default tint `ink` @ 32%. |
| `SegmentedStorageBar(segments:height:)` | 6 | none | Composition: categories, kinds, ages. 2 pt gaps, radius 2 segments, radius 3 clip. Its legend is the list/tabs under it — no separate legend box. |
| `DeltaBar(delta:scale:)` | 6 | centre line `line` | Snapshot changes: growth right (review @ 75%), freed left (safe @ 75%). |

Selected/filtered segments stay at full opacity; others dim to 30%.

### 14.2 Treemap (`Charts/ExploreCanvas.swift`, `ExploreTreemapView`)

- Squarified layout (`SquarifiedTreemap`), computed off the main thread.
- Tiles inset 1.5 pt (3 pt gutters), radius `min(6, short side / 3)`,
  `.continuous`.
- Fill: the tile colour + a white top-to-bottom wash (14% → 0%; hover 28% →
  12%).
- No outlines; the selected tile (or any multi-selected) gets a 2 pt `accent`
  stroke.
- Labels inside, top-left at 8/7 pt: name in 12 medium `tileLabel` @ 85% (if
  tile > 52 × 22), size in mono 11 @ 60% below it (if > 80 × 46).
- Hover lightens the tile and shows a tooltip "Name — size".
- Click selects, double-click opens a folder; arrow keys move between
  neighbouring tiles; Return opens; ⌘↑ goes up.

### 14.3 Other charts (`LayoutChartView`)

| Chart | Style |
|---|---|
| Sunburst | Wedges with 1.5 pt `canvas`-coloured seams; selected wedge 2 pt `accent`; labels 11 medium `tileLabel` @ 85% when there's room. |
| Flame | Bars inset 1.5, radius ≤ 4; selected 2 pt `accent`; labels left-aligned 11 medium. |
| Bubbles | Packed circles; containers washed to 55%; faint `tileLabel` @ 8% outline; selected 2 pt `accent`; labels 11/9 medium. |
| Mind Map | Cards on `raised` with hairlines, coloured stubs. |
| Age Map | Treemap of age buckets with the treemap tile style + a list of files untouched for a year. |

Colour modes (Visualize ▸ Color): By folder, By type, By age — all from the
data palette (§3.3–3.4). Size basis (Visualize ▸ Size): On disk / Logical.

Every chart exposes its items to VoiceOver (`chartAccessibility`) and to the
keyboard (`chartKeyboard`).

### 14.4 Category rows (Overview)

Dot (8 pt, data colour) · name (`body`, 150 pt) · 3 pt proportion bar in the
same colour · mono size (`figureStrong`, 76) · mono % (40). 36 pt rows, hover
fill, the whole row is a button.

---

## 15. The shell

`AppShellView.swift`. One surface (`canvas`), hairlines between zones.

### 15.1 Top bar (44 pt)

Left to right:
- sidebar toggle (compact windows only, icon button);
- **one search field** (max ~460 pt) with a `⌘K` Kbd inside — typing or
  Return opens the command palette with what was typed;
- a mono "Rescanning · N items" status while a rescan runs on an existing
  tree;
- spacer;
- **Cleanup** — a quiet button with a trash icon and an `accent` count
  capsule when items are staged; opens the Cleanup sheet (⇧⌘⌫);
- **Rescan** — an icon button whose menu offers Quick Update / Full Rescan.

Hairline under the bar. Appearance and text size live in the View menu and
Settings, not the top bar.

### 15.2 Sidebar (212 pt × text scale)

- Brand: `DiskMapWordmark` (13 pt mark), 18 pt side padding, 16 top, 14
  bottom.
- Sections: MAIN · FIND · CLEAN · EXPLORE as `MonoLabel`s, 18 pt apart.
- Nav rows: 28 pt tall, radius 6, 8 pt outer / 10 pt inner padding, 16 pt
  icon column.
  - Idle: `body` `ink2`, icon `ink3`.
  - Selected: `bodyEmphasis` `ink`, icon `accent`, `accentSoft` fill.
  - Locked (before a scan): `ink3`, help "Scan your Mac first."
- **Trailing figures** (mono `figureSmall` `ink3`) for pages whose catalog is
  already built — Safe to Review, Caches, Old Downloads, Large Media,
  Forgotten (bytes), Developer (reclaimable), Duplicates (group count).
  They never trigger a catalog build, and the figure gives way when the name
  needs the room.
- Saved searches section (when any).
- **Volume footer**: hairline, drive icon + volume name, a 2 pt usage bar,
  mono "120 GB free of 500 GB" (or "Scan to see capacity").

Navigation order (⌘1–⌘9 follow it): Overview · Find · Biggest Files · Biggest
Folders · Forgotten Files · Duplicates · Safe to Review · Caches · Old
Downloads · Large Media · File Browser · Visualize · Developer Storage ·
Applications · Snapshots.

### 15.3 Compact windows

Below the compact width the sidebar becomes an overlay toggled from the top
bar; the inspector becomes a drawer below 1200 pt.

---

## 16. Overlays: palette, sheets, popovers, toast

### 16.1 Command palette (⌘K)

560 × 440, `raised`, radius 12, hairline, shadow (§6), over a 25% black
scrim.
- Field row 52 pt: magnifier, 15 pt field, `esc` Kbd.
- Sections as `MonoLabel`s: ACTIONS, FILES, FOLDERS, APPLICATIONS.
- Rows ≥ 40 pt: 13 pt icon (`accent` when highlighted), name
  `bodyEmphasis`, subtitle `secondary` (mono for file paths), `↩` Kbd on the
  highlighted row, `accentSoft` highlight.
- ↑/↓ move the highlight (hover moves it too), Return runs it, Esc closes.
- Structured queries (`size>1GB`, `ext:mp4`) show a "Show all in Find —
  N matches · X" command first; problems appear in `review` text under the
  field.
- Footer 34 pt: `↑↓ move`, `↩ run`, and "Nothing here deletes — cleanup only
  opens review".

### 16.2 Sheets

| Sheet | Size | Layout |
|---|---|---|
| Cleanup | min 640 × 480 | Header (title "Cleanup", mono "X freed when you empty the Trash", Done secondary, **Move to Trash…** primary — disabled while measuring) · hairline · list grouped by source with `SectionHeader`s · "Last cleanup" disclosure row (count, relative time, Put Back link, expandable mono receipt). Rows: 28 pt icon, name, parent path, mono "frees" caption; hover Quick Look / Remove; danger text when Trash would damage a tool. Removing a queue entry doesn't ask (it never touches the file). |
| Explain my storage | min 520 × 440 | MonoLabel "FROM YOUR LAST SCAN", title, Done · the free-space sentence in `heading` · "What's going on" stories · "Next steps" rows (safety dot, name, detail, mono size, "Review ›" link — each opens its page) · mono footnote. |
| Save Snapshot | 420 wide | Title, one sentence, Name and Note fields, Cancel (secondary, Esc) and Save Snapshot (primary, Return). |
| Save Search | system | Name field, query in mono. |

### 16.3 Popovers

Overview's **Why?**: 340 pt, `raised`, 24 pt padding, `MonoLabel` "WHY THE
NUMBERS DIFFER", the reconciliation sentence, the clone note with "Count
clones once…" link to Settings.

### 16.4 Toast

Capsule, 34 pt tall, 14 pt padding, `raised` fill, hairline, shadow, text
`bodyEmphasis`, 12 pt below the top bar, centred; slides down + fades over
200 ms (none with Reduce Motion), auto-dismisses.

### 16.5 Menu bar panel

300 pt, 16 pt padding, `raised`:
- volume name as a `MonoLabel`;
- "X free" (20 semibold mono digits) + "of Y" (mono `ink3`);
- 2 pt usage bar (`danger` when under 10% free, with a "Low on space"
  label);
- **one** change line: this week's change when history exists, else the
  change since the last scan;
- "Last scan  ~ · 2 h ago" in mono;
- stale-projects line when relevant;
- hairline, then **Rescan** (primary) and **Open DiskMap** (secondary).

"Hide from Menu Bar" is in the panel's context menu, the DiskMap menu and
Settings. The menu bar label is an `internaldrive` glyph, or "X free" with a
warning glyph when low.

---

## 17. Page by page

### Overview
Single reading column, max 880, 32 side margins, 32 between sections.
1. **Hero**: volume `MonoLabel`; `display` "120 GB free" (numeric-text
   transition); mono "of 500 GB · 76% used" + a `SafetyLabel` only when
   tight/low; 6 pt capacity bar (`ink` @ 55%, health colour when low), max
   520; coverage sentence + **Why?** popover.
2. Notice when folders couldn't be read ("Grant access").
3. **Where it's going**: `SectionHeader` + "Open in Visualize →"; 6 pt stacked
   bar; category rows (§14.4) that open Find `kind:`, Visualize or Biggest
   Files.
4. Two columns (one when narrow): **Worth reviewing** (header total
   "~243.7 MB", "Explain my storage" link; link rows with a safety dot, name,
   tail-truncated detail, mono size, chevron) and **What grew this week**
   (with history) or **Biggest files** (top 5 with 20 pt icons).
5. Mono footer: scan kind and time, "Full Rescan" link after a quick update.

First run: treemap mark (220 × 132, five data-palette tiles), `MonoLabel`
"LOCAL · FAST · PRIVATE", 30 pt headline "See where your space went.", one
paragraph, **Scan This Mac** (primary, Return) + Choose Folder… (secondary),
dashed hairline, four numbered mono hints. Scanning: `MonoLabel` phase,
`display` item counter, current folder in mono, figure strip (Found,
Items/s), "Largest so far" bars (`accent` @ 60%), Cancel Scan (secondary).

### Find
Header "N matches · X"; query field (placeholder shows the syntax), Sort menu,
Save… (quiet, ⌘S); token chips (Large, Old, Duplicated, Cached, Media,
Downloads, Folders) — a chip adds/removes its token in the query; a mono
"what this means" line; problems in `review`. Start state: "Try" examples
(mono query + meaning), "Keep one in the sidebar" starter links, a two-column
key reference. Results: kit rows (kind, modified, size) with ⌘-click
multi-select and File/Folder inspector. A single bare word sorted by size runs
on the name index (instant); everything else on `FileQuery`.

### Biggest Files
Header "N files · X"; search, folder token chip, Sort; kind chips with counts
(Video, Disk Image, Archive, Application, Document, Other — "Other" collects
kinds without a chip); column header; kit rows with 24 pt icons and parent
path; FileInspector. Row facts are computed once per ranking (§23).

### Biggest Folders
Header "N folders · X here"; back + breadcrumb; search, "Show technical" chip
at a volume root; folder rows ("N files · N folders", proportion bar, size,
drill chevron; Protected label); FolderInspector.

### Forgotten Files
Figure strip (Reviewable, Likely forgotten, Worth reviewing); age stacked bar
whose legend filters; tabs All / Likely forgotten / Worth reviewing /
Excluded; search + chips (Over 1 GB, Downloads, Media) + Sort; rows with a
confidence dot label, short age, size; FileInspector with "Why it was
flagged", excluded files not stageable; multi-select toolbar stages only
reviewable files.

### Duplicates
Header with Search Again (secondary) after a run; figure strip (Groups,
Copies, Extra copies free); groups as `SectionHeader`s ("2 COPIES · 3 MB
EACH · APFS CLONE"); copy rows in `CheckRow` with "Keeper" in `safe` text;
footer "Select extra copies"; FileInspector explaining same contents / shared
storage; the last copy of a group can't be staged (inspector or ⌘⌫ says
"Keep at least one copy").

### Safe to Review
Header "X · N items"; one stacked bar whose segments are the tabs (All,
Caches, Build output, Packages, Other); search; "Caches by app →" link on the
Caches tab; `CheckRow` rows (icon, name, "detail · category", safety label,
size); footer "Select generally safe"; ReviewableInspector.

### Caches
Header "X · N apps" (the subtitle carries "won't touch your documents"); bar of
the top six apps + remainder; tabs All / Safe to clear / Review first; search
+ real Sort (Largest, Name); app-icon rows; footer "Select all generally
safe"; Reveal acts on ticked rows.

### Old Downloads
Header with "Reveal Downloads" (quiet); figure strip (In Downloads, Older than
30d); search + Size + Sort; age chips (All, 30d+, 90d+, 6mo+, 1y+) | type chips
with counts; rows with safety label, kind, short age, size (first 200);
FileInspector with "Why it's here".

### Large Media
Header "X · N files"; one thumbnail strip (six 140 × 80, accent outline on the
selected one) only while unfiltered and sorted by size; search + Where / Age /
Size / Sort menus; type chips; rows with 32 × 22 thumbnails, location, age,
size; FileInspector with a 260 × 146 preview and Duration / Dimensions facts.

### File Browser
Back/forward + breadcrumb + inspector toggle; the current folder as the page
title with mono "size · items"; one composition bar with inline legend; search
+ Sort; column header (Name, Kind, Modified, Size + bar); one-line rows
(36 pt) with ⌘-click multi-select; the inspector shows the selected row only
(empty hint otherwise). Double-click or Return opens a folder.

### Visualize
Title row: "Visualize", View chips (falls back to a menu), Color and Size
menus, inspector toggle. Path row: back/forward, breadcrumb, mono folder total.
The canvas without a frame (radius 10 clip). Selection toolbar when
multi-selecting. "Largest items" disclosure with six kit rows and "Open in File
Browser →". Footer mono note "Area is space on disk · double-click a folder to
open it". Shared File/Folder inspectors. No scan: the first-run hero.

### Developer Storage
Header "N tools · N projects"; one notice; figure strip (Developer storage,
Reclaimable, Likely keep); category bar whose legend filters Items; tabs
Projects / Items / Opportunities / By tool; search (+ category token chip).
Projects rows: ecosystem icon, name, "ecosystem · path", Git dot label,
rebuild, last change, reclaimable, size. Items: `CheckRow` with ecosystem,
safety, size; Trash-unsafe items can't be ticked. By tool (the former
Regenerable Data): groups per quick-win category with note and "Add all to
Cleanup", checkbox rows, FolderInspector. DeveloperInspector as in §12.

### Applications
Header (no actions); figure strip (Installed, Total size, Worth reviewing);
search + Sort; chips on their own row (All, Large, Not recently used, App
Store, Other, System); `CheckRow` rows with 28 pt app icons, publisher
(cleaned from the bundle's copyright line), status dot (Keep neutral), source,
last used, size; footer "Select not recently used"; one-column inspector.

### Snapshots
Header with **Save Snapshot** (the page's primary) and the "not backups"
sentence once; a 250 pt history column (All / Favorites chips; rows: name +
star, mono date or "Now", mono used; actions in the context menu); a Compare
line (Before ⇄ After menus); Compare: `display` signed delta in ink + "over N
days", Before/Now 6 pt bars, one mono line "Grew X · Freed Y · Mac free ±Z",
the story sentence, mismatch notice; tabs Biggest changes / All changes over
change rows (icon, name, before→after or parent, kind dot label, delta bar,
signed mono delta, drill chevron).

### Settings
Native grouped form, 480 wide. Sections: Scanning (APFS clones picker + one
sentence), History (toggle + one sentence), Updates, General (Text size, Show
in Menu Bar). Captions `secondary` `ink2`, one sentence each.

---

## 18. States: empty, loading, error, locked

| State | Component | Spec |
|---|---|---|
| Empty | `DiskMapEmptyState(symbol:title:message:primaryTitle:primaryAction:secondaryTitle:secondaryAction:)` | 20 pt `ink3` symbol, `bodyEmphasis` title, `secondary` `ink2` message (centred, ≤ 2 lines), optional primary/secondary buttons, 32 pt padding, centred in the available space. Title says what's missing ("No files match"), message says what to do ("Try another type or clear the search."). |
| Loading | `DiskMapLoadingState(title:detail:fraction:processed:total:onCancel:)` | Indeterminate spinner or a 320 pt determinate bar, `bodyEmphasis` title, `secondary` detail, mono "processed / total", optional Cancel (secondary). Used by catalog gates ("Finding forgotten files…"), Duplicates, FolderInspector ("Reading folder"). |
| Error | `DiskMapEmptyState` with `exclamationmark.triangle`, "Try again" + "Clear". | |
| Locked | Sidebar rows dimmed before the first scan; pages show the first-run hero. | |
| Not on disk | Inspector note "This isn't on disk any more."; Reveal does nothing for cloud-only files. | |

---

## 19. Motion

| Motion | Duration | Curve |
|---|---|---|
| Row hover, hover actions fade | 120 ms | ease-out |
| Palette highlight scroll | 100 ms | ease-out |
| Inspector toggle, disclosure | 150 ms | ease-in-out / ease-out |
| Toast in/out, compact sidebar | 200 ms | ease-in-out; move from top + opacity |
| Figures (display, scan counter) | system | `contentTransition(.numericText())` |
| Scan "largest so far" bars | 250 ms | ease-out |

With **Reduce Motion**: no toast slide, no compact-sidebar animation, no
numeric-text transitions, no bar animations; the palette scrim darkens
(35%) instead of fading. Nothing in the app loops or pulses.

---

## 20. Accessibility

- **Rows are buttons** with a full label: "Holiday 2023.mov, Video, 180 MB,
  modified 1 year ago". Selected rows carry `.isSelected`.
- **Row actions** (`.rowActions`): Quick Look, Reveal in Finder, Add to Cleanup
  as VoiceOver custom actions on every row; plus "Open" for folders, "Show in
  Treemap" in Age Map, "Remove from Cleanup" in the sheet.
- **Checkboxes**: toggle trait, "Mark <name>", value checked/unchecked.
- **Charts** expose every tile/wedge/bar as an element with name, size and
  share, selectable and openable; decorative bars are hidden
  (`accessibilityHidden`) when a list next to them carries the same data.
- **Icon buttons** always have a text label; `Kbd` chips are hidden.
- **Keyboard**: every list (§10.6), every chart (arrows, Return, ⌘↑, Space,
  ⌘-click equivalent), the palette (↑↓ ↩ esc), ⌘1–⌘9 navigation, ⌘K, ⇧⌘⌫,
  ⌘S (save search), ⌘F (find), ⌘[ / ⌘] (File Browser).
- **Text size** (§4.3) up to 1.3×; layouts are checked at Largest.
- **Increase Contrast** swaps `line`, `ink2`, `ink3` for the HC values (§3.1).
- **Reduce Motion** (§19).
- Contrast: `ink` on `canvas` ≈ 13:1 light / 18:1 dark; `ink2` meets 4.5:1 on
  `canvas` in both; `ink3` is for labels and decorative text only — never the
  sole carrier of meaning.

Details and the per-screen audit: `docs/ACCESSIBILITY.md`.

---

## 21. Writing: voice, verbs and formats

### 21.1 Voice

Plain, specific, calm. Say what is true and what to do. No exclamation marks,
no "Oops", no marketing. Prefer numbers to adjectives ("180 MB untouched for
2 years", not "huge old file").

### 21.2 Verbs (one per action)

| Use | Never |
|---|---|
| Add to Cleanup | Stage, Review selected, Add selected to review, Add to review |
| In Cleanup | Staged, Queued |
| Move to Trash… | Delete, Remove permanently, Clean |
| Remove from Cleanup | Unstage, Delete from queue |
| Reveal in Finder | Open in Finder, Show in Finder |
| Quick Look | Preview |
| Copy Path | Copy location |
| Show in Visualize / Show in File Browser / Open in File Browser | View in Explore, Visualize this folder |
| Put Back | Restore, Undo cleanup |
| Rescan / Quick Update / Full Rescan | Refresh, Re-scan |

### 21.3 Safety words

Safe · Generally safe · Review first · Protected · Keep · Excluded · Keeper.
Always paired with a dot; always followed somewhere by the reason and the
consequence (inspector `SafetyLine`).

### 21.4 Formats

- Bytes: `ByteFormat.string` everywhere ("561.8 MB", "13.45 GB", "0 bytes").
- Counts: `countLabel(n, "file")` → "1 file", "21 files" (locale digits).
- Ages: `RelativeAge` (§10.3). Dates in facts: abbreviated date + short time.
- Percent: whole numbers in lists ("21%"), one decimal in inspectors
  ("<0.1%").
- Deltas: "+1.2 GB", "−340 MB", "±0" (true minus sign).
- Separators: "  ·  " (two spaces either side) in mono summaries, " · " in
  prose subtitles.
- Paths: relative to the scan root in rows ("Movies/clips/"); `~`-abbreviated
  in facts.

### 21.5 Recurring sentences

- Snapshots: "Snapshots record sizes, not files; they are not backups." —
  once, in the subtitle.
- Palette: "Nothing here deletes — cleanup only opens review".
- Cleanup: "X freed when you empty the Trash".
- Toast: "Added to Cleanup — ⇧⌘⌫ to review".

---

## 22. Dark mode and high contrast

- Dark is near-black (`#0B0B0C`), not grey; raised surfaces are only one step
  up (`#141416`); hairlines `#26262A`.
- The accent brightens to `#9A8BF0`; safety colours brighten (§3.2).
- The primary button inverts: light ink (`#F2F2F3`) fill with near-black text.
- Data colours and `tileLabel` stay the same in both appearances.
- High contrast (both appearances) darkens/lightens `line`, `ink2` and `ink3`
  only; everything else is already high-contrast.
- The snapshot harness renders `light`, `dark`, `hc-light`, `hc-dark`
  (`--appearance`); check all four.

---

## 23. Performance rules for views

The redesign found a lag that came from layout code, not drawing. Rules:

1. **Never compute a list in a computed property that rows read.** A row
   asking "am I selected?" must not re-run the page's filter and sort. Work
   out `visible` and the active id **once per draw** (a `let` at the top of
   `body` or the list function) and pass them to rows.
2. **Pre-compute row facts off the main thread.** Paths, kinds, display
   strings and search keys for a ranked list are built once per ranking in a
   detached task (Biggest Files `Entry`), not per row per draw.
3. **Re-filter on change, not on draw.** Keep the filtered list in `@State`
   and recompute it in `.onChange` of the filter inputs.
4. **Subtree walks never run on the main thread.** `FolderInsight.build`,
   composition totals, treemap layout, catalogs and the duplicate search all
   run detached; views show a loading state meanwhile.
5. **Lists are lazy** (`LazyVStack`) and capped (500 / 300 / 200 rows with a
   "showing the first N" note).
6. Hover state lives inside the row (`KitRow`'s own `@State`), so hovering
   redraws one row, not the page.

---

## 24. Building a new page — checklist

- [ ] `PageHeader` with an eyebrow naming the section, one-sentence subtitle,
      a mono summary *or* one action.
- [ ] At most one `FigureStrip`; no figure repeated anywhere on screen.
- [ ] One filter row: search → chips → menus.
- [ ] Rows are `KitRow` inside a `Button`; `CheckRow` + `KitCheckbox` if the
      page ticks; `.rowActions`, `.listKeyboard`, accessibility label.
- [ ] Column header with `ColumnHeaderLabel`s at the same widths as the
      row columns; size column last.
- [ ] Shared inspector (File / Folder / Reviewable), or a new one built from
      `InspectorHeader`, `FactRow`, `Note`, `SafetyLine`, `InspectorActions`.
- [ ] One primary button on the whole screen.
- [ ] Staging through `model.stageRow` / `stageForCleanup` /
      `stageReviewTargets`; toast, no sheet.
- [ ] Empty, loading and no-match states.
- [ ] No literal colours, radii or font sizes; tokens only.
- [ ] Nothing filtered or sorted per row (§23).
- [ ] Harness entry and render in four appearances, at Largest text and in a
      1000 × 700 window.

---

## 25. Do and don't

| Do | Don't |
|---|---|
| Separate sections with a hairline and space | Wrap every section in a card |
| Show a figure once, in mono | Repeat the total in the header, a card and the footer |
| Use a dot + word for safety | Colour a row, pill or button green/amber/red |
| Use violet for selection, focus, links | Introduce a blue "info" or a purple "developer" accent |
| One ink primary; secondary outline for the rest | Two filled buttons side by side |
| Put navigation in the inspector's overflow menu | Stack five full-width buttons in the inspector |
| Chips that filter, tabs that switch views | Pills that look like chips but navigate |
| Hover actions + the same actions in the context menu | Hover-only actions |
| Toast after staging | Open the Cleanup sheet automatically |
| Relative paths in rows | Absolute `/Users/…/…` paths in list rows |
| Middle-truncate names and paths | Tail-truncate file names |
| Precompute row data once | Recompute the page's filter inside each row |

---

## 26. File map

| File | Contains |
|---|---|
| `Sources/DiskMapApp/DesignSystem.swift` | `DiskMapTheme` (colours, palettes), `DiskMapSpace`, `DiskMapRadius`, `DiskMapMetric`, `TextSize`, `DiskMapType`, `ProportionBar`, `SegmentedStorageBar`, the five button styles, `countLabel` |
| `Sources/DiskMapApp/Kit/Kit.swift` | `MonoLabel`, `Kbd`, `Hairline`, `PageHeader`, `HeaderSummary`, `Figure`/`FigureStrip`, `SectionHeader`, `Chip`, `KitTabs`, `SafetyLabel`, `ColumnHeaderLabel`, `RowBackground`, `RowHoverActions`, `InspectorHeader`, `FactRow`, `Note`, `SafetyLine`, `InspectorActions`, `InspectorColumn`, `RelativeAge`, `relativeParent` |
| `Sources/DiskMapApp/Kit/KitRows.swift` | `KitRow`, `KitCheckbox`, `CheckRow`, `MonoColumn`, `TextColumn`, `RowSeparator`, `MultiSelectMark`, `FileInspector`, `FolderInspector` |
| `Sources/DiskMapApp/Kit/ReviewTargets.swift` | `ReviewTargetRow`, `ReviewTargetIcon`, `ReviewableInspector`, `ReviewSelectionFooter`, `ReviewFooter`, `ScanModel.stageReviewTargets` |
| `Sources/DiskMapApp/Kit/BrandMark.swift` | `DiskMapMark`, `DiskMapWordmark` |
| `Sources/DiskMapApp/SharedChrome.swift` | `DiskMapSearchField`, `DiskMapMenu`, empty/loading states, `SelectionToolbar`, `DiskMapNoticeBanner`, `AdaptiveInspectorSplit`, `FileIdentityIcon`, `MediaThumbnailView` |
| `Sources/DiskMapApp/AppShellView.swift` | Top bar, sidebar, volume footer, toast, palette overlay, Explain sheet |
| `Sources/DiskMapApp/Charts/ExploreCanvas.swift` | Chart switcher, treemap |
| `Sources/DiskMapApp/LayoutChartView.swift` | Sunburst, flame, bubbles, mind map |
| `Sources/DiskMapApp/ExploreColoring.swift` | Folder / type / age colouring for charts |
| `Sources/IconRender/main.swift` | App icon variants (4 = logo, default) |
| `Sources/DiskMapCore/file-type-categories.json` | Category colours |
| `docs/brand/diskmap-logo.png` | Source logo |

---

## 27. Verifying a change

```bash
swift build
scripts/test.sh
scripts/render-all.sh          # 19 screens × light, dark, hc-light, hc-dark → build/visual
```

Snapshot harness flags (`SnapshotHarness.swift`), run on the built binary with
`--scan /tmp/DiskMapVisualFixture` (from `scripts/make-visual-fixture.sh`):

| Flag | Does |
|---|---|
| `--snapshot-dir DIR` | Write PNGs (and turns the harness on) |
| `--appearance light\|dark\|hc-light\|hc-dark` | Appearance |
| `--snapshot-size WxH` | Window size (check 1280×820, 1440×900, 1000×700) |
| `--snapshot-destinations a,b` | Which pages |
| `--explore-modes all\|"Age Map,Bubbles"` | Visualize modes |
| `--deterministic` | Fixed volume figures, default text size, no history |
| `--settle S` | Seconds to wait before capture |
| `--click "x,y;x,y"` / `--keys down,return` / `--scroll` | Input, then a second `-keys` capture |
| `--find-query "…"` | Open Find with a query |
| `--find-duplicates` | Run the duplicate search first |
| `--stage "rel/path,…"` | Add paths to Cleanup |
| `--sheet cleanup\|explain` | Capture a sheet |
| `--palette` | Capture the command palette |
| `--dump-ax` | Write the accessibility tree as text |
| `-TextSize largest` | Text size (before any valueless flag; not with `--deterministic`) |

Put `-Key value` and `--flag value` pairs **before** valueless flags such as
`--deterministic`, or macOS treats the value as a document to open.

Before merging a UI change, also check: one primary per screen, no repeated
figure, no literal colour (`grep -rn "Color(red:" Sources/DiskMapApp`), and
the safety greps in AGENTS.md (no networking outside `Updates.swift`, no
`removeItem`/`unlink`, excluded-paths list unchanged).
