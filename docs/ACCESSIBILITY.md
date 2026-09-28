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

## Still open

- Full keyboard grid navigation inside Treemap/Sunburst canvases.
- A user-facing text-size setting wired to `DiskMapType.scale` (macOS has no
  system Dynamic Type for arbitrary apps).
- VoiceOver rotor custom actions for stage/reveal.
