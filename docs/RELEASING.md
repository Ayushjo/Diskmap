# Releasing DiskMap

Everything here runs on the maintainer's Mac. Nothing is pushed or uploaded
by the scripts; the network is touched only by `notarytool` (when signing
exists) and by Sparkle in the shipped app when a user opts in.

## Build

```bash
scripts/make-icon.sh        # optional: re-render Resources/AppIcon.icns (variant 4, the logo, by default)
scripts/build-adhoc.sh      # dist/DiskMap.app + dist/DiskMap-<VERSION>.dmg, ad-hoc signed
```

- Version: the `VERSION` file. Build number: `git rev-list --count HEAD`.
- Ad-hoc signed apps need right-click → Open on first launch (no Developer ID yet).

## Choosing the icon

Four variants are drawn in code (`Sources/IconRender`) and previewed in
`docs/icon/variant-{1,2,3,4}.png`. Variant 4 — the logo's "D" mark on a paper
tile, redrawn from `docs/brand/diskmap-logo.png` — is the default; 1–3 are the
earlier treemap designs (`scripts/make-icon.sh 1`, `2` or `3` switches). The
same mark is `DiskMapMark` in the app (sidebar wordmark); keep the two copies
in step.

## Updates (Sparkle, opt-in)

The app can check for updates only when the build carries both a feed URL and
the EdDSA public key; without them (as now) it has no update server at all.
To turn updates on for a release:

1. On your Mac, generate a key pair with Sparkle's `generate_keys` (in the
   Sparkle release you build against). It stores the **private key in your
   login keychain** and prints the public key. Never commit the private key.
2. Host an appcast (`appcast.xml`) — GitHub Releases or Pages.
3. Build with
   `DISKMAP_FEED_URL=https://…/appcast.xml DISKMAP_SPARKLE_PUBLIC_KEY=<public key> scripts/build-adhoc.sh`.
4. Sign the dmg with Sparkle's `sign_update dist/DiskMap-<VERSION>.dmg` and add
   the item to the appcast.

Users get updates only if they turn on Settings ▸ Updates ▸ "Check for updates
automatically" or choose DiskMap ▸ Check for Updates…. AGENTS.md rule 2 names
this as the single networking exception.

## Notarization (not set up)

`scripts/notarize.sh` signs with a Developer ID (hardened runtime), notarizes
and staples. It exits with a message until `DEVELOPER_ID` and `NOTARY_PROFILE`
exist. `.github/workflows/release.yml` is manual-only and fails fast without
the secrets it lists.
