# freedisk.space

A native, open-source storage analyzer for macOS, with a Windows port in progress. See what fills a disk, follow large folders to their files, understand developer artifacts and duplicates, and review every cleanup action before anything moves to Trash.

**Website:** [Next.js project](design/website-motion-v1/README.md) · **Domain:** [freedisk.space](https://freedisk.space) · **License:** MIT

## Mac: build and run

Requires macOS 14 or later and the Swift toolchain.

```bash
swift build
scripts/test.sh
swift run DiskMapApp
```

To make an ad-hoc signed app and disk image for local use:

```bash
scripts/build-adhoc.sh
open dist/freedisk.space.app
```

On first launch of an ad-hoc build, use **right-click → Open** if Gatekeeper warns about an unidentified developer. This is not a notarized public release. See [SETUP.md](SETUP.md) for details.

The source repository and SwiftPM executable target retain their original `DiskMap` names. The read-only CLI also remains `diskmap` so existing scripts keep working:

```bash
swift run -c release diskmap scan ~/code --top 10
swift run -c release diskmap dev --reclaimable --older-than 6m
swift run -c release diskmap find ~ ext:mp4 size\>500MB
```

## Windows

The native WPF port lives in [windows/README.md](windows/README.md). It can be built from source with .NET 10; a verified one-click installer has not been published.

## How cleanup works

The app analyzes local files and stages proposed removals in a visible Cleanup queue. Only a separate final confirmation moves selected items to Trash. Cloud-only files are not opened for duplicate comparison or preview. Scans and cleanup do not send your data to a server. Optional Sparkle update checks are the only network exception, and are off by default.

## Project structure

- `Sources/DiskMapCore/`: scanning, catalogs, duplicate detection, visualization layout, and CleanupQueue.
- `Sources/DiskMapApp/`: native macOS interface and AppKit integrations.
- `Sources/diskmap/`: compatible read-only CLI.
- `windows/`: native Windows port.
- `docs/PRD.md`, `docs/ARCHITECTURE.md`, `TASKS.md`: feature targets, decisions, and work history.

The internal module names, existing bundle identifier (`com.ayushjo.diskmap`), snapshot directories, cache directories, and preference keys remain unchanged so existing installs and saved scans continue to work under the new public name.
