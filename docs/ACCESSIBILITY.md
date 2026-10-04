# DiskMap accessibility notes

## Done on `feature/product-redesign`

- Sidebar destinations expose VoiceOver labels and selected traits.
- Top search field and command palette have accessibility labels.
- Command palette rows announce title + subtitle.
- Explore toast animation respects Reduce Motion.
- Scan progress uses `accessibilityIdentifier("scan-progress")`.
- Explore mode chips use `explore-mode-*` identifiers for UI tests.

## Done on `feat/dark-mode` (2026-09-28)

- **Dark mode.** Every surface, text and semantic token resolves per
  appearance; the app follows the system setting (the five forced
  `.preferredColorScheme(.light)` calls are gone). Data tiles keep one palette
  in both appearances and carry a fixed dark label, so charts stay legible.
- **Increase Contrast.** Secondary text, disabled text and card borders have
  stronger variants, read from `accessibilityDisplayShouldIncreaseContrast`.
  Rendered with the harness override (`--appearance hc-light|hc-dark`): 2.87%
  of pixels change, 95% of them darker in light mode — the muted text and
  borders. The system-flag read itself was not exercised by flipping the
  setting (a system accessibility setting; left to the user).
- **Type scale.** 524 of 612 hand-set font sizes now go through
  `DiskMapType` and one `scale` factor, which is what a text-size pass needs.
- **Counts pluralise** ("1 item", not "1 items") and follow the system locale.
- **Keyboard (TASK-062).** Every ranked list — Find, Biggest Files/Folders,
  Forgotten, Duplicates, Safe to Review, Caches, Old Downloads, Large Media,
  Developer Storage, Applications, File Browser — moves with ↑↓ or j/k once a
  row is selected, Space opens Quick Look, Return reveals in Finder (opens a
  folder in File Browser), ⌘⌫ adds the row to Cleanup (the queue, never the
  Trash). Menu: ⌘1–⌘9 go to the first nine sidebar items in order (Overview, Find, Biggest Files, Biggest Folders, Forgotten Files, Duplicates, Safe to Review, Caches, Old Downloads — Search folded into Find in the calm-UI pass), ⌘↑/⌘↓ enclosing /
  open folder in Visualize and File Browser, ⌘R quick rescan, ⇧⌘R full
  rescan, ⇧⌘⌫ cleanup queue, ⇧⌘E export. Checked by sending real key events
  to the app's window through the snapshot harness (`--click`, `--keys`).

## Done on `feat/a11y-rows` (TASK-078, 2026-10-03)

- **Rows are buttons.** File Browser, Find, Visualize's table,
  Applications, Large Media and Old Downloads selected a row with a tap
  gesture, which VoiceOver does not see as a control and synthetic clicks
  never reached (checked: a harness click left File Browser's render
  byte-identical). Each row is now a checkbox ("Mark …") plus one plain
  button that selects, labelled "name, kind, size, modified", with
  "Selected" when it is, and a named action for the double-click meaning
  ("Open" for folders, "Reveal in Finder" for files). Double-click still
  works (a simultaneous double-tap gesture). Forgotten Files' age bar
  segments are buttons and hidden from VoiceOver (the legend under them is
  the same set of buttons, with text); Age Map rows got "Show in Explore".
- **Charts have elements.** Treemap, Sunburst, Flame and Bubbles are drawn
  on a Canvas; each now exposes "Treemap of Downloads" with the 60 biggest
  items as buttons — "Dune (2021)….mkv, 24.28 GB, 37 percent" — whose
  default action selects and, for folders, an "Open" action drills in
  (`ChartAccessibility` in core builds the labels; unit-tested). The Mind
  Map was already buttons.
- **Checked without Accessibility permission.** `--dump-ax` makes the
  snapshot harness write each screen's accessibility tree from inside the
  app (`<screen>-ax.txt`), so the structure above was read, not assumed.
  Found in passing: the Appearance menu button reports its symbol name
  ("circle.lefthalf.filled") as its title — for TASK-085.
- Not done here: a live VoiceOver walk-through (needs a person at the
  machine); the tree dumps stand in for it.

## Done on `feat/a11y-text-keys` (TASK-085, 2026-10-03)

- **Text size.** View ▸ Text Size (⌘+ / ⌘− / ⌘0) and Settings: Smaller 0.9 ·
  Default · Larger 1.15 · Largest 1.3. Every `DiskMapType` token is computed
  from one scale, the 87 hand-set point sizes and 27 system text styles that
  bypassed the tokens now go through it, the sidebar widens with it, and the
  window is rebuilt on change. Checked by rendering all 17 destinations at
  Largest (1440×900): text grows, columns stay aligned, nothing overlaps;
  long labels wrap or truncate.
- **Chart keyboard.** Treemap, Sunburst, Flame, Bubbles and Mind Map take
  focus when shown (and on click). Treemap: arrows go to the nearest tile in
  that direction. The others: ←/→ siblings by size, ↑ parent, ↓ largest
  child. Return opens a folder, ⌘↑ goes up, Space is Quick Look, ⌘Space adds
  to the selection. Verified with key events through the harness (treemap:
  → → selects Dune, then The Holdovers; sunburst: → → ↓ ends on the largest
  child of the second-largest folder), repeated runs identical.
- **VoiceOver row actions.** File Browser, Find, Biggest Files,
  Biggest Folders, Large Media and Old Downloads rows offer Add to Cleanup
  (the queue, never the Trash), Reveal in Finder and Quick Look (checked in
  the `--dump-ax` tree). The Appearance button now reads "Appearance, Match
  System" instead of its symbol's name.

## Still open

- Row actions on the remaining lists (Safe to Review, Caches, Duplicates,
  Developer Storage, Applications).
- A live VoiceOver walk-through by a person; the tree dumps stand in for it.
