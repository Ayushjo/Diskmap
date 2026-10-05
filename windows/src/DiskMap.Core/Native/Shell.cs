using System.Runtime.InteropServices;

namespace DiskMap.Core.Native;

/// <summary>
/// The Recycle Bin refused an item — too big for the bin's size limit on
/// that drive. Nothing was deleted; the item is exactly where it was.
/// </summary>
public sealed class RecycleRefusedException(string path)
    : IOException($"Too big for the Recycle Bin — nothing was deleted: {path}")
{
    public string Path { get; } = path;
}

/// <summary>
/// Shell interop for the Recycle Bin: IFileOperation with FOF_ALLOWUNDO —
/// the Win32 "move to Recycle Bin", the same guarantee FileManager.trashItem
/// gives on macOS: recoverable, never a hard delete.
///
/// When an item can't fit in the bin, the shell's next step is to destroy
/// it (and, with FOF_WANTNUKEWARNING, to pop a per-item "permanently
/// delete?" box). Instead, <see cref="RecycleOnlySink"/> vetoes every
/// delete that isn't a recycle (PreDeleteItem without
/// TSF_DELETE_RECYCLE_IF_POSSIBLE) — verified on a 60 GB sparse folder:
/// the veto lands on the folder before any child is touched, every file
/// survives, no dialog appears. Vetoed items come back as refusals so the
/// app can ask once.
/// </summary>
internal static class Shell32
{
    private const uint FOF_SILENT = 0x0004;
    private const uint FOF_NOCONFIRMATION = 0x0010;
    private const uint FOF_ALLOWUNDO = 0x0040;
    private const uint FOF_NOCONFIRMMKDIR = 0x0200;
    private const uint FOF_NOERRORUI = 0x0400;
    private const uint TSF_DELETE_RECYCLE_IF_POSSIBLE = 0x80;
    private const uint SIGDN_FILESYSPATH = 0x80058000;
    private const int HRESULT_ERROR_CANCELLED = unchecked((int)0x800704C7);
    private static readonly Guid FileOperationClsid = new("3ad05575-8857-4850-9277-11b85bdb8e09");

    /// <summary>Moves one path to the Recycle Bin. Null on success; <see cref="RecycleRefusedException"/> when the bin refused it.</summary>
    public static Exception? RecycleItem(string path)
    {
        try
        {
            var refused = RecycleItems([path]);
            if (refused.Count > 0) return new RecycleRefusedException(path);
            return File.Exists(path) || Directory.Exists(path)
                ? new IOException($"Recycle Bin operation didn't move {path} — it may be in use")
                : null;
        }
        catch (Exception ex) { return new IOException($"Recycle Bin operation failed for {path}: {ex.Message}", ex); }
    }

    /// <summary>
    /// Moves many paths in one shell operation (one engine spin-up instead
    /// of one per item). Returns the requested paths the bin refused; other
    /// outcomes are read by the caller from what's still on disk.
    /// </summary>
    public static HashSet<string> RecycleItems(IReadOnlyCollection<string> paths)
    {
        var refused = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (paths.Count == 0) return refused;
        var op = (IFileOperation)Activator.CreateInstance(Type.GetTypeFromCLSID(FileOperationClsid, throwOnError: true)!)!;
        try
        {
            op.SetOperationFlags(FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI | FOF_NOCONFIRMMKDIR);
            var sink = new RecycleOnlySink();
            op.Advise(sink);
            int queued = 0;
            foreach (var path in paths)
            {
                try
                {
                    SHCreateItemFromParsingName(path, IntPtr.Zero, typeof(IShellItem).GUID, out var item);
                    op.DeleteItem(item, IntPtr.Zero);
                    queued++;
                }
                catch (COMException) { /* vanished or unreadable — the caller sees it still/never there */ }
            }
            if (queued == 0) return refused;
            try { op.PerformOperations(); }
            catch (COMException ex) when (ex.HResult == HRESULT_ERROR_CANCELLED) { /* our own veto */ }
            catch (COMException) { /* partial failure — read from disk by the caller */ }
            // Map vetoed shell items back to the requested paths.
            foreach (var vetoed in sink.Vetoed)
            {
                var owner = paths.FirstOrDefault(p =>
                    vetoed.Equals(p.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase)
                    || vetoed.StartsWith(p.TrimEnd('\\') + '\\', StringComparison.OrdinalIgnoreCase));
                if (owner is not null) refused.Add(owner);
            }
        }
        finally { Marshal.ReleaseComObject(op); }
        return refused;
    }

    /// <summary>
    /// <see cref="RecycleItems"/> spread over parallel shell operations.
    /// The shell walks every file under a recycled folder single-threaded
    /// (~0.25 ms/file, no flag avoids it), so a node_modules-heavy commit
    /// is bound by that walk: each folder gets its own operation and they
    /// run side by side, while loose files share batches of 64 (one call
    /// per file costs an engine spin-up each). Measured 6 × 8k-file
    /// folders: 12.9 s batched → 5.6 s; 500 files: 11.5 s serial → 2.7 s.
    /// <paramref name="onDone"/> gets the number of paths each finished job covered.
    /// </summary>
    public static HashSet<string> RecycleItemsParallel(IReadOnlyCollection<string> paths, Action<int>? onDone = null)
    {
        var refused = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var jobs = paths.Where(Directory.Exists).Select(d => (IReadOnlyCollection<string>)[d])
            .Concat(paths.Where(p => !Directory.Exists(p)).Chunk(64))
            .ToList();
        Parallel.ForEach(
            System.Collections.Concurrent.Partitioner.Create(jobs, System.Collections.Concurrent.EnumerablePartitionerOptions.NoBuffering),
            new ParallelOptions { MaxDegreeOfParallelism = Math.Clamp(Environment.ProcessorCount, 2, 8) },
            job =>
            {
                HashSet<string> jobRefused;
                try { jobRefused = RecycleItems(job); }
                catch { jobRefused = []; }   // read from disk by the caller
                lock (refused) refused.UnionWith(jobRefused);
                onDone?.Invoke(job.Count);
            });
        return refused;
    }

    /// <summary>
    /// Lets recycles through and vetoes every other delete — the shell's
    /// "too big for the bin, destroy it instead" fallback never runs.
    /// </summary>
    private sealed class RecycleOnlySink : IFileOperationProgressSink
    {
        public readonly List<string> Vetoed = [];

        public int PreDeleteItem(uint dwFlags, IShellItem item)
        {
            if ((dwFlags & TSF_DELETE_RECYCLE_IF_POSSIBLE) != 0) return 0;
            try
            {
                item.GetDisplayName(SIGDN_FILESYSPATH, out var path);
                lock (Vetoed) Vetoed.Add(path.TrimEnd('\\'));
            }
            catch { /* still vetoed, just unnamed */ }
            return HRESULT_ERROR_CANCELLED;
        }

        public int StartOperations() => 0;
        public int FinishOperations(int hrResult) => 0;
        public int PreRenameItem(uint f, IShellItem i, string? n) => 0;
        public int PostRenameItem(uint f, IShellItem i, string? n, int hr, IShellItem? c) => 0;
        public int PreMoveItem(uint f, IShellItem i, IShellItem d, string? n) => 0;
        public int PostMoveItem(uint f, IShellItem i, IShellItem d, string? n, int hr, IShellItem? c) => 0;
        public int PreCopyItem(uint f, IShellItem i, IShellItem d, string? n) => 0;
        public int PostCopyItem(uint f, IShellItem i, IShellItem d, string? n, int hr, IShellItem? c) => 0;
        public int PostDeleteItem(uint f, IShellItem i, int hr, IShellItem? c) => 0;
        public int PreNewItem(uint f, IShellItem d, string? n) => 0;
        public int PostNewItem(uint f, IShellItem d, string? n, string? t, uint a, int hr, IShellItem? c) => 0;
        public int UpdateProgress(uint total, uint soFar) => 0;
        public int ResetTimer() => 0;
        public int PauseTimer() => 0;
        public int ResumeTimer() => 0;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    private static extern void SHCreateItemFromParsingName(
        string path, IntPtr pbc, [MarshalAs(UnmanagedType.LPStruct)] Guid riid, out IShellItem item);

    [ComImport, Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellItem
    {
        void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
        void GetParent(out IShellItem ppsi);
        void GetDisplayName(uint sigdnName, [MarshalAs(UnmanagedType.LPWStr)] out string ppszName);
        void GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
        void Compare(IShellItem psi, uint hint, out int piOrder);
    }

    [ComImport, Guid("947aab5f-0a5c-4c13-b4d6-4bf7836fc9f8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IFileOperation
    {
        uint Advise(IFileOperationProgressSink pfops);
        void Unadvise(uint dwCookie);
        void SetOperationFlags(uint dwOperationFlags);
        void SetProgressMessage([MarshalAs(UnmanagedType.LPWStr)] string pszMessage);
        void SetProgressDialog(IntPtr popd);
        void SetProperties(IntPtr pproparray);
        void SetOwnerWindow(IntPtr hwndOwner);
        void ApplyPropertiesToItem(IShellItem psiItem);
        void ApplyPropertiesToItems(IntPtr punkItems);
        void RenameItem(IShellItem psiItem, [MarshalAs(UnmanagedType.LPWStr)] string pszNewName, IntPtr pfopsItem);
        void RenameItems(IntPtr pUnkItems, [MarshalAs(UnmanagedType.LPWStr)] string pszNewName);
        void MoveItem(IShellItem psiItem, IShellItem psiDestinationFolder, [MarshalAs(UnmanagedType.LPWStr)] string? pszNewName, IntPtr pfopsItem);
        void MoveItems(IntPtr punkItems, IShellItem psiDestinationFolder);
        void CopyItem(IShellItem psiItem, IShellItem psiDestinationFolder, [MarshalAs(UnmanagedType.LPWStr)] string? pszCopyName, IntPtr pfopsItem);
        void CopyItems(IntPtr punkItems, IShellItem psiDestinationFolder);
        void DeleteItem(IShellItem psiItem, IntPtr pfopsItem);
        void DeleteItems(IntPtr punkItems);
        uint NewItem(IShellItem psiDestinationFolder, uint dwFileAttributes, [MarshalAs(UnmanagedType.LPWStr)] string pszName, [MarshalAs(UnmanagedType.LPWStr)] string? pszTemplateName, IntPtr pfopsItem);
        void PerformOperations();
        [return: MarshalAs(UnmanagedType.Bool)] bool GetAnyOperationsAborted();
    }

    [ComImport, Guid("04b0f1a7-9490-44bc-96e1-4296a31252e2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IFileOperationProgressSink
    {
        [PreserveSig] int StartOperations();
        [PreserveSig] int FinishOperations(int hrResult);
        [PreserveSig] int PreRenameItem(uint dwFlags, IShellItem psiItem, [MarshalAs(UnmanagedType.LPWStr)] string? pszNewName);
        [PreserveSig] int PostRenameItem(uint dwFlags, IShellItem psiItem, [MarshalAs(UnmanagedType.LPWStr)] string? pszNewName, int hrRename, IShellItem? psiNewlyCreated);
        [PreserveSig] int PreMoveItem(uint dwFlags, IShellItem psiItem, IShellItem psiDestinationFolder, [MarshalAs(UnmanagedType.LPWStr)] string? pszNewName);
        [PreserveSig] int PostMoveItem(uint dwFlags, IShellItem psiItem, IShellItem psiDestinationFolder, [MarshalAs(UnmanagedType.LPWStr)] string? pszNewName, int hrMove, IShellItem? psiNewlyCreated);
        [PreserveSig] int PreCopyItem(uint dwFlags, IShellItem psiItem, IShellItem psiDestinationFolder, [MarshalAs(UnmanagedType.LPWStr)] string? pszNewName);
        [PreserveSig] int PostCopyItem(uint dwFlags, IShellItem psiItem, IShellItem psiDestinationFolder, [MarshalAs(UnmanagedType.LPWStr)] string? pszNewName, int hrCopy, IShellItem? psiNewlyCreated);
        [PreserveSig] int PreDeleteItem(uint dwFlags, IShellItem psiItem);
        [PreserveSig] int PostDeleteItem(uint dwFlags, IShellItem psiItem, int hrDelete, IShellItem? psiNewlyCreated);
        [PreserveSig] int PreNewItem(uint dwFlags, IShellItem psiDestinationFolder, [MarshalAs(UnmanagedType.LPWStr)] string? pszNewName);
        [PreserveSig] int PostNewItem(uint dwFlags, IShellItem psiDestinationFolder, [MarshalAs(UnmanagedType.LPWStr)] string? pszNewName, [MarshalAs(UnmanagedType.LPWStr)] string? pszTemplateName, uint dwFileAttributes, int hrNew, IShellItem? psiNewItem);
        [PreserveSig] int UpdateProgress(uint iWorkTotal, uint iWorkSoFar);
        [PreserveSig] int ResetTimer();
        [PreserveSig] int PauseTimer();
        [PreserveSig] int ResumeTimer();
    }
}
