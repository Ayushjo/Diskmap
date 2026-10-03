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
| `getattrlistbulk` walk | `FindFirstFileExW` (FindExInfoBasic + LARGE_FETCH) work-queue |
| — | `$MFT` parse: `FSCTL_GET_NTFS_VOLUME_DATA` + record 0's `$DATA` run list, parallel raw reads (admin) |
| `O_NOFOLLOW` symlink skip | `FILE_ATTRIBUTE_REPARSE_POINT` skip (symlinks/junctions) |
| iCloud dataless placeholders | OneDrive/cloud placeholders (`OFFLINE`, `RECALL_ON_*`) |
| `ATTR_FILE_ALLOCSIZE` | `FILE_STANDARD_INFO.AllocationSize` / `GetCompressedFileSizeW` / cluster rounding |
| APFS clones (`F_LOG2PHYS_EXT`) | `FSCTL_GET_RETRIEVAL_POINTERS` extent-map compare (ReFS clones, hardlinks) |
| `FileManager.trashItem` | `SHFileOperationW` + `FOF_ALLOWUNDO` (Recycle Bin) — never a direct delete |
| `NSOpenPanel` | `IFileOpenDialog` (`FOS_PICKFOLDERS`) |
| Quick Look | Reveal in Explorer (`explorer /select`) |
| `task_info` RSS | `GetProcessMemoryInfo` working set |
| `/Applications` + `~/Library` | Registry Uninstall hives + `%APPDATA%`/`%LOCALAPPDATA%`/`%PROGRAMDATA%` |

Snapshots use the same versioned little-endian `DMAP` format as the macOS
build — files are interchangeable.

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

- Block-clone detection only works where Windows supports shared extents:
  ReFS volumes (Dev Drive). On NTFS the same code path detects hardlinks.
- No Quick Look equivalent — Reveal in Explorer replaces it.
- Hard links: the MFT path charges a multiply-linked file once (the macOS
  rule, first name reached breadth-first; the rest read 0 with
  `NodeFlags.HardLink`). The FindFirstFileExW walk can't see link counts,
  so it still counts every name — WinSxS-heavy totals differ by backend.
