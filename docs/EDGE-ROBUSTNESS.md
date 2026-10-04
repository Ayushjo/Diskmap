# Edge-case / external-volume robustness (TASK-027)

Date: 2026-09-14. Machine: AYUSHs-MacBook-Air.local.

## Method note

`hdiutil create … -fs ExFAT` fails with **Operation not permitted** in both
Grok Bot’s shell and Terminal.app on this Mac. Workaround:
`hdiutil attach -nomount ram://…` + `diskutil erasevolume ExFAT DISKMAP`
(`scripts/make-exfat-fixture.sh`). Volume name must be ≤11 chars for ExFAT.

No network (SMB/AFP/NFS) mounts were present; that check remains open if a
share appears later.

## Results

| Case | Result | Evidence |
|---|---|---|
| ExFAT scan | **OK** | `/Volumes/DISKMAP/edge-cases` scan: 302 items, 0.014 s, no hang. `docs/perf-results/exfat-ramdisk-probe.txt` |
| `F_LOG2PHYS_EXT` on ExFAT | **Fails cleanly** | `fcntl` returns -1, **errno 45 (Operation not supported)**. |
| CloneDetector on ExFAT | **false, no crash** | `areLikelyClones(a,b/c)` all false (extent map nil → false). |
| DuplicateFinder on ExFAT | **hashes, no hang** | Independent copies grouped with `sharesStorage=false`. |
| Combining Unicode name | **OK** | `café.txt` (U+0301) seen in scan (`saw_combining=true`). |
| Deep path (40 dirs) | **OK** | `leaf.txt` found. |
| Large file on ExFAT | **OK** | 64 MB file scanned (10 GB skipped — RAM disk size). 10 GB sparse on APFS fixture also scanned earlier without hang. |
| Permission denied dir | **OK** | APFS fixture `chmod 000` secret dir recorded; scan completes (`EdgeCaseRobustnessTests`). |
| Full Disk Access denied | **Proxy only** | No clean way to revoke FDA for Terminal in automation; `chmod 000` stands in. Real FDA still needs a manual System Settings check. |
| Network share | **Not available** | `mount` showed no smb/afp/nfs. |

### Observation (not a crash)

ExFAT emits many identical AppleDouble `._*` sidecar files. DuplicateFinder
correctly hashes them into a large content group (`sharesStorage=false`).
Consider skipping `._*` / AppleDouble in candidates later — not required to
close TASK-027.

## Fixes applied

None required for crash/hang. Added:
- `EdgeCaseRobustnessTests` (unicode/deep/denied/copies + optional ExFAT).
- `scripts/make-exfat-fixture.sh` (RAM ExFAT recipe).
