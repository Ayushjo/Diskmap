using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace DiskMap.Core.Native;

/// <summary>
/// Hand-written P/Invoke surface for the scanner, clone detector, and
/// process-memory probes. Kept in one file so the Win32 footprint stays
/// auditable — nothing else in the codebase talks to the OS directly.
/// </summary>
internal static partial class Win32
{
    // ---- File enumeration (FindFirstFileExW path) ----

    public const int FindExInfoBasic = 1;
    public const int FindExSearchNameMatch = 0;
    public const int FindExSearchLimitToDirectories = 1;
    public const int FIND_FIRST_EX_LARGE_FETCH = 4;
    public const int FIND_FIRST_EX_ON_DISK_ENTRIES_ONLY = 1;

    public const uint FILE_ATTRIBUTE_DIRECTORY = 0x10;
    public const uint FILE_ATTRIBUTE_REPARSE_POINT = 0x400;
    public const uint FILE_ATTRIBUTE_SPARSE_FILE = 0x200;
    public const uint FILE_ATTRIBUTE_COMPRESSED = 0x800;
    public const uint FILE_ATTRIBUTE_OFFLINE = 0x1000;
    public const uint FILE_ATTRIBUTE_RECALL_ON_OPEN = 0x40000;
    public const uint FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS = 0x400000;

    // FILETIME fields are 4-byte aligned in the real struct (DWORD
    // alignment), so Pack=4 is required — a default pack aligns the i64
    // fields to 8 and shifts cFileName by 4 bytes.
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public unsafe struct WIN32_FIND_DATAW
    {
        public uint dwFileAttributes;
        public long ftCreationTime;
        public long ftLastAccessTime;
        public long ftLastWriteTime;
        public uint nFileSizeHigh;
        public uint nFileSizeLow;
        public uint dwReserved0;
        public uint dwReserved1;
        public fixed char cFileName[260];
        public fixed char cAlternateFileName[14];
    }

    public sealed class SafeFindHandle() : SafeHandleZeroOrMinusOneIsInvalid(true)
    {
        protected override bool ReleaseHandle() => FindClose(handle);
    }

    [LibraryImport("kernel32.dll", EntryPoint = "FindFirstFileExW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    public static partial SafeFindHandle FindFirstFileExW(
        string lpFileName,
        int fInfoLevelId,
        out WIN32_FIND_DATAW lpFindFileData,
        int fSearchOp,
        IntPtr lpSearchFilter,
        int dwAdditionalFlags);

    [LibraryImport("kernel32.dll", EntryPoint = "FindNextFileW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool FindNextFileW(SafeFindHandle hFindFile, out WIN32_FIND_DATAW lpFindFileData);

    [LibraryImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool FindClose(IntPtr hFindFile);

    // ---- Handles ----

    public const uint GENERIC_READ = 0x80000000;
    public const uint GENERIC_WRITE = 0x40000000;
    public const uint FILE_SHARE_READ = 0x1;
    public const uint FILE_SHARE_WRITE = 0x2;
    public const uint FILE_SHARE_DELETE = 0x4;
    public const uint OPEN_EXISTING = 3;
    public const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
    public const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
    public const uint FILE_FLAG_OVERLAPPED = 0x40000000;
    public const uint FILE_READ_ATTRIBUTES = 0x80;
    public const uint FILE_LIST_DIRECTORY = 0x1;

    public static readonly IntPtr INVALID_HANDLE_VALUE = new(-1);

    [LibraryImport("kernel32.dll", EntryPoint = "CreateFileW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    public static partial SafeFileHandle CreateFileW(
        string lpFileName,
        uint dwDesiredAccess,
        uint dwShareMode,
        IntPtr lpSecurityAttributes,
        uint dwCreationDisposition,
        uint dwFlagsAndAttributes,
        IntPtr hTemplateFile);

    // ---- DeviceIoControl / FSCTL ----

    public const uint FSCTL_GET_NTFS_VOLUME_DATA = 0x00090064; // CTL_CODE(9,25,0,0)
    public const uint FSCTL_GET_RETRIEVAL_POINTERS = 0x00090073; // CTL_CODE(9,28,0,0)
    public const uint FSCTL_GET_NTFS_FILE_RECORD = 0x00090068; // CTL_CODE(9,26,0,0)

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static unsafe partial bool DeviceIoControl(
        SafeFileHandle hDevice,
        uint dwIoControlCode,
        void* lpInBuffer,
        int nInBufferSize,
        void* lpOutBuffer,
        int nOutBufferSize,
        out int lpBytesReturned,
        IntPtr lpOverlapped);

    [StructLayout(LayoutKind.Sequential)]
    public struct NTFS_VOLUME_DATA_BUFFER
    {
        public long VolumeSerialNumber;
        public long NumberSectors;
        public long TotalClusters;
        public long FreeClusters;
        public long TotalReserved;
        public uint BytesPerSector;
        public uint BytesPerCluster;
        public uint BytesPerFileRecordSegment;
        public uint ClustersPerFileRecordSegment;
        public long MftValidDataLength;
        public long MftStartLcn;
        public long Mft2StartLcn;
        public long MftZoneStart;
        public long MftZoneEnd;
    }

    // RETRIEVAL_POINTERS_BUFFER: { uint ExtentCount; i64 StartingVcn;
    //   struct { i64 NextVcn; i64 Lcn } Extents[] } — variable length,
    // parsed manually out of a raw buffer.

    [StructLayout(LayoutKind.Sequential)]
    public struct FILE_ID_DESCRIPTOR
    {
        public uint dwSize;
        public int Type;        // 0 = FileIdType (use FileId)
        public long FileId;
    }

    [LibraryImport("kernel32.dll", EntryPoint = "OpenFileById", SetLastError = true)]
    public static partial SafeFileHandle OpenFileById(
        SafeFileHandle hVolumeHint,
        ref FILE_ID_DESCRIPTOR lpFileId,
        uint dwDesiredAccess,
        uint dwShareMode,
        IntPtr lpSecurityAttributes,
        uint dwFlagsAndAttributes);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static unsafe partial bool ReadFile(
        SafeFileHandle hFile,
        void* lpBuffer,
        int nNumberOfBytesToRead,
        out int lpNumberOfBytesRead,
        IntPtr lpOverlapped);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool SetFilePointerEx(
        SafeFileHandle hFile,
        long liDistanceToMove,
        out long lpNewFilePointer,
        uint dwMoveMethod);

    [LibraryImport("kernel32.dll", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool GetVolumeInformationByHandleW(
        SafeFileHandle hFile,
        IntPtr lpVolumeNameBuffer,
        int nVolumeNameSize,
        out uint lpVolumeSerialNumber,
        out uint lpMaximumComponentLength,
        out uint lpFileSystemFlags,
        IntPtr lpFileSystemNameBuffer,
        int nFileSystemNameSize);

    /// <summary>
    /// Returns the low 32 bits of the compressed size; INVALID_FILE_SIZE
    /// (0xFFFFFFFF) on failure — check GetLastError when it returns that.
    /// </summary>
    [LibraryImport("kernel32.dll", EntryPoint = "GetCompressedFileSizeW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    public static partial uint GetCompressedFileSizeW(string lpFileName, out uint lpFileSizeHigh);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetFileInformationByHandle(SafeFileHandle hFile, out BY_HANDLE_FILE_INFORMATION lpFileInformation);

    // FILETIME fields are 4-byte aligned here too — same Pack=4 rule.
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct BY_HANDLE_FILE_INFORMATION
    {
        public uint dwFileAttributes;
        public long ftCreationTime;
        public long ftLastAccessTime;
        public long ftLastWriteTime;
        public uint dwVolumeSerialNumber;
        public uint nFileSizeHigh;
        public uint nFileSizeLow;
        public uint nNumberOfLinks;
        public uint nFileIndexHigh;
        public uint nFileIndexLow;
    }

    // FILE_STANDARD_INFO via GetFileInformationByHandleEx (FileStandardInfo = 1)
    public const int FileStandardInfo = 1;

    [StructLayout(LayoutKind.Sequential)]
    public struct FILE_STANDARD_INFO
    {
        public long AllocationSize;   // allocated size on disk
        public long EndOfFile;        // logical size
        public uint NumberOfLinks;
        [MarshalAs(UnmanagedType.Bool)] public bool DeletePending;
        [MarshalAs(UnmanagedType.Bool)] public bool Directory;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetFileInformationByHandleEx(
        SafeFileHandle hFile,
        int FileInformationClass,
        out FILE_STANDARD_INFO lpFileInformation,
        int dwBufferSize);

    [LibraryImport("kernel32.dll", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool GetDiskFreeSpaceW(
        string lpRootPathName,
        out uint lpSectorsPerCluster,
        out uint lpBytesPerSector,
        out uint lpNumberOfFreeClusters,
        out uint lpTotalNumberOfClusters);

    // ---- Process memory ----

    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_MEMORY_COUNTERS_EX
    {
        public uint cb;
        public uint PageFaultCount;
        public nuint PeakWorkingSetSize;
        public nuint WorkingSetSize;
        public nuint QuotaPeakPagedPoolUsage;
        public nuint QuotaPagedPoolUsage;
        public nuint QuotaPeakNonPagedPoolUsage;
        public nuint QuotaNonPagedPoolUsage;
        public nuint PagefileUsage;
        public nuint PeakPagefileUsage;
        public nuint PrivateUsage;
    }

    [LibraryImport("kernel32.dll")]
    public static partial IntPtr GetCurrentProcess();

    [LibraryImport("psapi.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool GetProcessMemoryInfo(
        IntPtr Process,
        out PROCESS_MEMORY_COUNTERS_EX ppsmemCounters,
        uint cb);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    public static partial int GetLastError();

    // ---- File times ----

    /// <summary>FILETIME (100ns since 1601) → days since Unix epoch.</summary>
    public static int FileTimeToModifiedDay(long fileTime)
    {
        const long unixEpochInFileTime = 11644473600_0000000L;
        if (fileTime <= unixEpochInFileTime) return 0;
        long days = (fileTime - unixEpochInFileTime) / (10_000_000L * 86_400L);
        return days > int.MaxValue ? 0 : (int)days;
    }

    /// <summary>
    /// Extended-length prefix so paths over 260 chars still work.
    /// </summary>
    public static string ExtendedPath(string path)
    {
        if (path.StartsWith(@"\\?\")) return path;
        if (path.StartsWith(@"\\")) return @"\\?\UNC\" + path[2..];
        return @"\\?\" + path;
    }
}
