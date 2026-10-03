# Visualize polish — 2026-09-16

Scope: the Visualize workspace, its six modes, and responsiveness while preparing their data.

Changes:
- Compact mode controls with a menu fallback at narrow widths.
- Chart receives remaining height; largest-items table is a bounded optional disclosure.
- Explicit size basis and color controls; quieter folder colors and size labels in Treemap.
- Shared single-click inspection and double-click folder navigation across chart modes.
- Correct Back/Forward history and scan-root breadcrumb.
- Background chart preparation, background circle packing, cached Treemap geometry, and constant-time folder palette lookup.
- Size-basis analysis rebuild moved off the main actor.

Validation:
- Real home scan: approximately 1.84 million nodes, 238 GB.
- Opened Treemap, Sunburst, Flame, Bubbles, Mind Map, and Age Map in the running release app.
- Inspected compact and wide window layouts. The chart now fills the available workspace instead of a narrow strip.
- Corrected narrow-section text overflow discovered during live checks.
- Swift Testing: 97 tests pass, including bounded ranking compared with a complete reference sort and equal-size ties.
- Release build and ad-hoc signature verification pass.

Limits: UI checks are manual observations, not a measured frame-time benchmark or a complete VoiceOver audit. Other destinations remain outside this focused pass.
