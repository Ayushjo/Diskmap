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
dotnet run --project windows\app\DiskMap.App
```

Requires .NET 10 SDK. Runs unelevated; scans fall back to the
FindFirstFileExW walk. Run as administrator to enable the MFT fast path
(raw `$MFT` parse — the WizTree approach) for drive-root and near-root
scans.

## What maps to what

| macOS | Windows |
|---|---|
| `getattrlistbulk` walk | `FindFirstFileExW` (FindExInfoBasic + LARGE_FETCH) work-queue |
| — | `$MFT` parse via `FSCTL_GET_NTFS_VOLUME_DATA` + retrieval pointers (admin, near-root scans) |
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
- `MftScanner` is flagged `UNVERIFIED` until exercised elevated against a
  live volume; the fallback scanner is the tested path.
