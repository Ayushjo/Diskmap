using System.Runtime.InteropServices;

namespace DiskMap.Core.Native;

/// <summary>
/// Shell interop for the Recycle Bin. SHFileOperationW with FOF_ALLOWUNDO
/// is the Win32 path to "move to Recycle Bin" — the same guarantee
/// FileManager.trashItem provides on macOS: recoverable, never a hard
/// delete. Per-item calls keep per-item results (the macOS commit()
/// contract) and let failures stay staged.
/// </summary>
internal static class Shell32
{
    public const uint FO_DELETE = 0x3;
    public const ushort FOF_SILENT = 0x0004;
    public const ushort FOF_NOCONFIRMATION = 0x0010;
    public const ushort FOF_ALLOWUNDO = 0x0040;
    public const ushort FOF_NOERRORUI = 0x0400;
    public const ushort FOF_WANTNUKEWARNING = 0x4000;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct SHFILEOPSTRUCTW
    {
        public IntPtr hwnd;
        public uint wFunc;
        [MarshalAs(UnmanagedType.LPWStr)] public string pFrom;
        public IntPtr pTo;
        public ushort fFlags;
        [MarshalAs(UnmanagedType.Bool)] public bool fAnyOperationsAborted;
        public IntPtr hNameMappings;
        public IntPtr lpszProgressTitle;
    }

    /// <summary>0 on success; nonzero = a shell error code for that item.</summary>
    [DllImport("shell32.dll", EntryPoint = "SHFileOperationW", CharSet = CharSet.Unicode)]
    public static extern int SHFileOperation(ref SHFILEOPSTRUCTW lpFileOp);

    /// <summary>
    /// Moves one path to the Recycle Bin. Returns null on success, or an
    /// exception describing the shell error. pFrom is a double-null-
    /// terminated path; the flags are the "recoverable delete" set —
    /// silent, no UI, recycle only, and warn if the item can't be recycled.
    /// </summary>
    public static Exception? RecycleItem(string path)
    {
        var op = new SHFILEOPSTRUCTW
        {
            hwnd = IntPtr.Zero,
            wFunc = FO_DELETE,
            pFrom = path + '\0',
            pTo = IntPtr.Zero,
            fFlags = (ushort)(FOF_SILENT | FOF_NOCONFIRMATION | FOF_NOERRORUI | FOF_ALLOWUNDO | FOF_WANTNUKEWARNING),
        };
        int result = SHFileOperation(ref op);
        if (result != 0)
            return new IOException($"Recycle Bin operation failed (0x{result:X}) for {path}");
        if (op.fAnyOperationsAborted)
            return new IOException($"Recycle Bin operation aborted by the system for {path}");
        return null;
    }
}
