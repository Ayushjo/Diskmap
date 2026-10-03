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
    public const uint SYNCHRONIZE = 0x00100000;
    public const uint FILE_SYNCHRONOUS_IO_NONALERT = 0x20;

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

    // ---- NtQueryDirectoryFile (batch enumeration with file ids) ----
    //
    // What FindFirstFileExW can't give us: the filesystem's file id, the
    // creation time, and the real on-disk AllocationSize — all inline per
    // entry, one syscall per page instead of per file. This is the same
    // directory query FindFirstFile itself is built on.
    //
    // FILE_ID_BOTH_DIR_INFORMATION (class 37, supported since Windows 8):
    //   +0  u32  NextEntryOffset
    //   +4  u32  FileIndex
    //   +8  i64  CreationTime        +16 LastAccessTime
    //   +24 i64  LastWriteTime       +32 ChangeTime
    //   +40 i64  EndOfFile (logical) +48 AllocationSize (on disk)
    //   +56 u32  FileAttributes      +60 FileNameLength (bytes)
    //   +64 u32  EaSize              +68 u8 ShortNameLength
    //   +70 WCHAR ShortName[12]      +96 i64 FileId
    //   +104 WCHAR FileName[]
    // Offsets verified live on Windows 11 by IdentityAndWalkTests —
    // the header docs get the newer Extd class numbering wrong, so the
    // stable documented class is the right choice.
    public const int FileIdBothDirectoryInformation = 37;

    public const int STATUS_SUCCESS = 0;
    public const int STATUS_NO_MORE_FILES = unchecked((int)0x80000006);
    public const int STATUS_BUFFER_OVERFLOW = unchecked((int)0x80000005);
    public const int STATUS_INVALID_INFO_CLASS = unchecked((int)0xC0000003);
    public const int STATUS_INVALID_PARAMETER = unchecked((int)0xC000000D);
    public const int STATUS_NOT_IMPLEMENTED = unchecked((int)0xC0000002);
    public const int STATUS_NO_SUCH_FILE = unchecked((int)0xC000000F);
    public const int STATUS_OBJECT_NAME_NOT_FOUND = unchecked((int)0xC0000034);
    public const int STATUS_ACCESS_DENIED = unchecked((int)0xC0000022);

    // CreateFileW failure codes consulted by the denied-directory report.
    public const int ERROR_FILE_NOT_FOUND = 2;
    public const int ERROR_PATH_NOT_FOUND = 3;
    public const int ERROR_ACCESS_DENIED = 5;
    public const int ERROR_NETWORK_ACCESS_DENIED = 65;

    [StructLayout(LayoutKind.Sequential)]
    public struct IO_STATUS_BLOCK
    {
        public IntPtr Status;
        public IntPtr Information;
    }

    [DllImport("ntdll.dll")]
    public static unsafe extern int NtQueryDirectoryFile(
        SafeFileHandle FileHandle,
        IntPtr Event,
        IntPtr ApcRoutine,
        IntPtr ApcContext,
        out IO_STATUS_BLOCK IoStatusBlock,
        byte* FileInformation,
        int Length,
        int FileInformationClass,
        [MarshalAs(UnmanagedType.Bool)] bool ReturnSingleEntry,
        IntPtr FileName,
        [MarshalAs(UnmanagedType.Bool)] bool RestartScan);

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

    // ---- USN journal (incremental rescan, WIN-031) ----

    public const uint FSCTL_QUERY_USN_JOURNAL = 0x000900F4; // CTL_CODE(9,61,0,0)
    public const uint FSCTL_READ_USN_JOURNAL = 0x000900BB;  // CTL_CODE(9,46,0,0)

    /// <summary>USN_JOURNAL_DATA_V0 — the journal's identity + next write cursor.</summary>
    [StructLayout(LayoutKind.Sequential)]
    public struct USN_JOURNAL_DATA_V0
    {
        public long UsnJournalID;
        public long FirstUsn;
        public long NextUsn;
        public long LowestValidUsn;
        public long MaxUsn;
        public long MaximumSize;
        public long AllocationDelta;
    }

    /// <summary>READ_USN_JOURNAL_DATA_V0 input block for FSCTL_READ_USN_JOURNAL.</summary>
    [StructLayout(LayoutKind.Sequential)]
    public struct READ_USN_JOURNAL_DATA_V0
    {
        public long StartUsn;
        public uint ReasonMask;
        public uint ReturnOnlyOnClose;
        public ulong Timeout;
        public ulong BytesToWaitFor;
        public ulong UsnJournalID;
    }

    // USN_REASON bits we parse (the rest still arrive under the mask).
    public const uint USN_REASON_DATA_OVERWRITE = 0x00000001;
    public const uint USN_REASON_DATA_EXTEND = 0x00000002;
    public const uint USN_REASON_DATA_TRUNCATION = 0x00000004;
    public const uint USN_REASON_NAMED_DATA_OVERWRITE = 0x00000010;
    public const uint USN_REASON_NAMED_DATA_EXTEND = 0x00000020;
    public const uint USN_REASON_NAMED_DATA_TRUNCATION = 0x00000040;
    public const uint USN_REASON_FILE_CREATE = 0x00000100;
    public const uint USN_REASON_FILE_DELETE = 0x00000200;
    public const uint USN_REASON_BASIC_INFO_CHANGE = 0x00008000;
    public const uint USN_REASON_RENAME_OLD_NAME = 0x00001000;
    public const uint USN_REASON_RENAME_NEW_NAME = 0x00002000;
    public const uint USN_REASON_HARD_LINK_CHANGE = 0x00010000;
    public const uint USN_REASON_COMPRESSION_CHANGE = 0x00020000;
    public const uint USN_REASON_REPARSE_POINT_CHANGE = 0x00100000;
    public const uint USN_REASON_CLOSE = 0x80000000;

    /// <summary>Read everything the journal can report.</summary>
    public const uint USN_REASON_ALL = 0xFFFFFFFF;

    // USN_RECORD_V2 layout (all little-endian):
    //   +0  u32 RecordLength          +4  u16 MajorVersion (2)
    //   +6  u16 MinorVersion          +8  u64 FileReferenceNumber
    //   +16 u64 ParentFileReference   +24 i64 Usn
    //   +32 i64 TimeStamp             +40 u32 Reason
    //   +44 u32 SourceInfo            +48 u32 SecurityId
    //   +52 u32 FileAttributes        +56 u16 FileNameLength (bytes)
    //   +58 u16 FileNameOffset        +60 WCHAR FileName[]
    public const int UsnRecordMinLength = 60;
    public const int UsnRecordVersion2 = 2;
    public const long UsnRecordMask = 0x0000FFFFFFFFFFFF;   // low 48 bits = record

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

    // ---- Token privileges ----
    //
    // Raw volume reads need SeBackupPrivilege/SeRestorePrivilege
    // *enabled* in the process token —
    // elevated tokens carry them present-but-disabled, so AdjustTokenPrivileges
    // is mandatory before touching $MFT. Without it the MFT path silently
    // fails and every scan falls back to FindFirstFileExW.

    public const uint TOKEN_ADJUST_PRIVILEGES = 0x20;
    public const uint TOKEN_QUERY = 0x8;
    public const uint SE_PRIVILEGE_ENABLED = 0x2;

    [StructLayout(LayoutKind.Sequential)]
    public struct LUID { public uint LowPart; public int HighPart; }

    [StructLayout(LayoutKind.Sequential)]
    public struct LUID_AND_ATTRIBUTES { public LUID Luid; public uint Attributes; }

    [StructLayout(LayoutKind.Sequential)]
    public struct TOKEN_PRIVILEGES
    {
        public uint PrivilegeCount;
        public LUID_AND_ATTRIBUTES Privileges;
    }

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool OpenProcessToken(
        IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool LookupPrivilegeValueW(
        string? lpSystemName, string lpName, out LUID lpLuid);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool AdjustTokenPrivileges(
        IntPtr TokenHandle,
        [MarshalAs(UnmanagedType.Bool)] bool DisableAllPrivileges,
        ref TOKEN_PRIVILEGES NewState,
        uint BufferLength,
        IntPtr PreviousState,
        IntPtr ReturnLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool CloseHandle(IntPtr hObject);

    /// <summary>
    /// Enables SeBackupPrivilege + SeRestorePrivilege on the current process
    /// token. Returns false when the process can't hold them (non-elevated).
    /// </summary>
    public static bool EnableBackupPrivileges()
    {
        if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out var token))
            return false;
        try
        {
            bool ok = true;
            foreach (var name in new[] { "SeBackupPrivilege", "SeRestorePrivilege" })
            {
                if (!LookupPrivilegeValueW(null, name, out var luid)) { ok = false; continue; }
                var tp = new TOKEN_PRIVILEGES
                {
                    PrivilegeCount = 1,
                    Privileges = new LUID_AND_ATTRIBUTES { Luid = luid, Attributes = SE_PRIVILEGE_ENABLED },
                };
                if (!AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero))
                    ok = false;
                // AdjustTokenPrivileges returns success even when a privilege
                // isn't assigned — GetLastError reports NOT_ALL_ASSIGNED.
                else if (Marshal.GetLastWin32Error() == 1300 /* ERROR_NOT_ALL_ASSIGNED */)
                    ok = false;
            }
            return ok;
        }
        finally
        {
            CloseHandle(token);
        }
    }
}
