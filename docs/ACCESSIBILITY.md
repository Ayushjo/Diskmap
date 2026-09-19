# DiskMap accessibility notes

## Done on `feature/product-redesign`

- Sidebar destinations expose VoiceOver labels and selected traits.
- Top search field and command palette have accessibility labels.
- Command palette rows announce title + subtitle.
- Explore toast animation respects Reduce Motion.
- Scan progress uses `accessibilityIdentifier("scan-progress")`.
- Explore mode chips use `explore-mode-*` identifiers for UI tests.

## Still open

- Full keyboard grid navigation inside Treemap/Sunburst canvases.
- High Contrast / Increase Contrast palette audit.
- Dynamic Type scaling pass across Overview cards.
- VoiceOver rotor custom actions for stage/reveal.
