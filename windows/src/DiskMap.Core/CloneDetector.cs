using DiskMap.Core.Native;
using Microsoft.Win32.SafeHandles;

namespace DiskMap.Core;

/// <summary>
/// Detects storage-sharing file copies by comparing physical extent maps —
/// the Windows equivalent of the macOS fcntl(F_LOG2PHYS_EXT) check.
///
/// Windows has no high-level "is this a clone of that" API either. The real
/// technique is FSCTL_GET_RETRIEVAL_POINTERS, which returns the file's
/// VCN→LCN map: two files whose logical offsets land on the same physical
/// clusters share backing storage. On Windows that's ReFS block clones
/// (FSCTL_DUPLICATE_EXTENTS_TO_FILE — what copy does on a Dev Drive volume)
/// and hardlinks. NTFS has no block cloning, so on NTFS this only fires for
/// hardlink-like shared extents.
///
/// A clone overwritten in the middle diverges in its extent map, so the
/// full map is compared — same rule as the macOS build. Extents are
/// comparable only within one volume, so the volume serial is checked
/// first.
/// </summary>
public static class CloneDetector
{
    private readonly record struct Extent(long FileOffset, long DeviceOffset, long LengthBytes);

    /// <summary>
    /// Full physical map, or null if the file can't be mapped (missing,
    /// empty, or a filesystem that doesn't answer FSCTL_GET_RETRIEVAL_POINTERS
    /// — e.g. exFAT, network shares).
    /// </summary>
    private static unsafe List<Extent>? ExtentMapOf(string path)
    {
        using var handle = Win32.CreateFileW(
            Win32.ExtendedPath(path), Win32.FILE_READ_ATTRIBUTES,
            Win32.FILE_SHARE_READ | Win32.FILE_SHARE_WRITE | Win32.FILE_SHARE_DELETE,
            IntPtr.Zero, Win32.OPEN_EXISTING,
            Win32.FILE_FLAG_BACKUP_SEMANTICS | Win32.FILE_FLAG_OPEN_REPARSE_POINT,
            IntPtr.Zero);
        if (handle.IsInvalid) return null;

        if (!Win32.GetFileInformationByHandleEx(handle, Win32.FileStandardInfo, out var info,
                sizeof(Win32.FILE_STANDARD_INFO)) || info.EndOfFile <= 0)
        {
            return null;
        }

        if (!Win32.GetVolumeInformationByHandleW(handle, IntPtr.Zero, 0, out uint serial,
                out _, out _, IntPtr.Zero, 0))
        {
            return null;
        }

        long fileSize = info.EndOfFile;
        var input = new long[1]; // STARTING_VCN_INPUT_BUFFER
        var outBuf = new byte[Math.Max(4096, (fileSize / 4096 / 8) * 16 + 64)];
        int bytesReturned;
        bool ok;
        fixed (void* inPtr = input, outPtr = outBuf)
        {
            ok = Win32.DeviceIoControl(
                handle, Win32.FSCTL_GET_RETRIEVAL_POINTERS,
                inPtr, sizeof(long), outPtr, outBuf.Length, out bytesReturned, IntPtr.Zero);
        }
        // ERROR_MORE_DATA = more extents than fit — fall back to a bigger buffer once.
        if (!ok && bytesReturned <= 0) return null;
        if (!ok) return null;

        int extentCount = BitConverter.ToInt32(outBuf, 0);
        long startingVcn = BitConverter.ToInt64(outBuf, 8);
        long clusterSize = ClusterSize(path);
        var extents = new List<Extent>(extentCount);
        long prevVcn = startingVcn;
        for (int i = 0; i < extentCount; i++)
        {
            int off = 16 + i * 16;
            long nextVcn = BitConverter.ToInt64(outBuf, off);
            long lcn = BitConverter.ToInt64(outBuf, off + 8);
            long length = (nextVcn - prevVcn) * clusterSize;
            // LCN -1 means a sparse (unallocated) run — encode as -1 so two
            // sparse runs never falsely "match" physical storage.
            long device = lcn == -1 ? -1 : lcn * clusterSize;
            extents.Add(new Extent(prevVcn * clusterSize, device, length));
            prevVcn = nextVcn;
        }
        return extents;
    }

    private static long ClusterSize(string path)
    {
        string? root = Path.GetPathRoot(Path.GetFullPath(path));
        if (root is not null
            && Win32.GetDiskFreeSpaceW(root, out uint sectors, out uint bytes, out _, out _)
            && sectors > 0 && bytes > 0)
        {
            return (long)sectors * bytes;
        }
        return 4096;
    }

    /// <summary>Same volume check: different serials can't share clusters.</summary>
    private static bool SameVolume(string pathA, string pathB)
    {
        string? rootA = Path.GetPathRoot(Path.GetFullPath(pathA));
        string? rootB = Path.GetPathRoot(Path.GetFullPath(pathB));
        return rootA is not null && string.Equals(rootA, rootB, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// True only when both files share the same physical extents across
    /// their whole length. A first-block match is not enough: a clone
    /// overwritten in the middle still shares the head extent and is not
    /// a duplicate.
    /// </summary>
    public static bool AreLikelyClones(string pathA, string pathB)
    {
        if (string.Equals(pathA, pathB, StringComparison.OrdinalIgnoreCase) || !SameVolume(pathA, pathB))
            return false;
        var mapA = ExtentMapOf(pathA);
        var mapB = ExtentMapOf(pathB);
        if (mapA is null || mapB is null || mapA.Count != mapB.Count || mapA.Count == 0)
            return false;
        for (int i = 0; i < mapA.Count; i++)
        {
            // Same file offsets, same device offsets, same lengths.
            if (mapA[i].FileOffset != mapB[i].FileOffset
                || mapA[i].DeviceOffset != mapB[i].DeviceOffset
                || mapA[i].LengthBytes != mapB[i].LengthBytes
                || mapA[i].DeviceOffset == -1)
            {
                return false;
            }
        }
        return true;
    }
}
