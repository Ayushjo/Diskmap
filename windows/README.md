# DiskMap for Windows

A native Windows port of DiskMap — the open-source disk-space analyzer —
keeping the same UI concepts and feature set as the macOS app: one scan
feeding a treemap plus six other views, content-based duplicate detection,
a staged cleanup queue that only ever moves things to the Recycle Bin,
snapshots, Quick Wins, and fully offline operation (no telemetry, no
network calls).

## Layout

```
windows/
  DiskMap.Win.slnx          solution
  src/DiskMap.Core/         headless core — tree model, layout engines,
                            scanners, dup/clone, cleanup, snapshots
  tests/DiskMap.Core.Tests/ xUnit suite
  app/DiskMap.App/          WPF desktop app
  app/DiskMap.Cli/          diskmap CLI — scan/find/dup/export/check/bench
```

## Build & run

```powershell
dotnet build windows\DiskMap.Win.slnx
dotnet test windows\DiskMap.Win.slnx
Start-Process windows\app\DiskMap.App\bin\Debug\net10.0-windows\DiskMap.App.exe
```

Requires .NET 10 SDK. The app requires administrator: Windows shows the
UAC prompt at every launch (`requireAdministrator` in `app.manifest`), so
`dotnet run` works only from an elevated terminal — from a normal one it
fails with "The requested operation requires elevation". Elevation is
what unlocks the MFT fast path (raw `$MFT` parse — the WizTree approach):
a drive root goes straight to it, a folder gets a 2-second walk first and
only a big subtree falls through to the MFT (which always reads the whole
`$MFT`). The FindFirstFileExW walk remains for non-NTFS drives; the
status line says which backend ran and why the MFT was skipped.

Measured on a 1 TB NVMe system drive (8.1M MFT records, 8M items): the
MFT scan is bound by reading the 8 GB `$MFT` (~1.3 GB/s on that drive,
the same read WizTree does), ~9 s end to end; the unelevated walk takes
70–200 s for the same drive. A hot drive throttles that read: at 75 °C+
the same NVMe managed ~0.45 GB/s and the scan took ~23 s — compare
against other tools back to back.

## What maps to what

| macOS | Windows |
|---|---|
| `getattrlistbulk` walk | `NtQueryDirectoryFile` (FileIdBothDirectoryInformation) work-queue — name, size, file id, creation time, allocation per entry |
| — | `$MFT` parse: `FSCTL_GET_NTFS_VOLUME_DATA` + record 0's `$DATA` run list, parallel raw reads (admin) |
| FSEvents rescan | USN journal replay (`FSCTL_QUERY/READ_USN_JOURNAL`) over a saved baseline in `ScanCache` — falls back to a full scan on any doubt |
| `O_NOFOLLOW` symlink skip | `FILE_ATTRIBUTE_REPARSE_POINT` skip (symlinks/junctions) |
| iCloud dataless placeholders | OneDrive/cloud placeholders (`OFFLINE`, `RECALL_ON_*`) — ☁ rows, never opened |
| `ATTR_FILE_ALLOCSIZE` | `AllocationSize` inline in dir enumeration / MFT `DATA` allocated size |
| inode number (`ATTR_FILE_INO`) | 64-bit file id (`FileId` field / FRN) — both backends record it |
| APFS clones (`F_LOG2PHYS_EXT`) | hard links share file id → charged once at rollup (lowest path); `FSCTL_GET_RETRIEVAL_POINTERS` for extent checks |
| `FileManager.trashItem` | `SHFileOperationW` + `FOF_ALLOWUNDO` (Recycle Bin) — never a direct delete |
| Put Back (Trash item origins) | `$Recycle.Bin` `$I` metadata parsed after a commit → `CleanupRecord` → restored |
| `NSOpenPanel` | `IFileOpenDialog` (`FOS_PICKFOLDERS`) |
| Quick Look | Reveal in Explorer + the inspector tabs (decided — no shell previewer hosting) |
| menu-bar extra | NotifyIcon tray: free space, last scan, rescan, open |
| ⌘K command palette | Ctrl+K popup: meaning line, top-8 hits, saved searches |
| ⌘R / ⌘⇧R | Ctrl+R rescan / Ctrl+Shift+R full rescan (drops the baseline) |
| `task_info` RSS | `GetProcessMemoryInfo` working set |
| `/Applications` + `~/Library` | Registry Uninstall hives + Store/MSIX (`AppModel\Repository\Packages`) + `%APPDATA%`/`%LOCALAPPDATA%`/`%PROGRAMDATA%` |
| Sparkle (opt-in) | **no updater** — `NetworkPolicyTests` greps sources for networking |

Snapshots use the same versioned little-endian `DMAP` format as the macOS
build — the codec writes v4 and reads v1–4, so files are interchangeable.

## Safety invariants (same as macOS)

- **Nothing deletes directly.** Cleanup stages first; commit moves items
  to the Recycle Bin via `SHFileOperation(FOF_ALLOWUNDO)` only. There is
  no unlink/`File.Delete` path.
- The excluded-prefix list in `CleanupQueue` (`C:\Windows`, Program Files,
  `ProgramData\Microsoft`, `$Recycle.Bin`, `System Volume Information`,
  `Recovery`, per-user OS state) is the last line of defense — changes to
  it must be called out explicitly.
- Cloud placeholders are recorded but never opened (enumeration doesn't
  recall content; opening would).

## Known gaps vs. the macOS build

- Block clones (shared extents): only ReFS supports them, and the
  per-file extent pass is deliberately not run during a scan (the same
  +14%-ish cost macOS declined). On a ReFS root the Overview says so —
  cloned copies count per copy. Hard links dedupe on every backend:
  file ids are recorded inline (MFT FRN, walk FileId) and the rollup
  charges a multiply-linked file once at its lowest path.
- No Quick Look equivalent — Reveal in Explorer plus the inspector's
  Overview/Contents/Insights tabs carry that surface.
- `diskmap dev` on the CLI is deferred — the Developer page has the
  full catalog in the app; the CLI covers scan/find/dup/export/check.
