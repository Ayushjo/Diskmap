using System.Runtime.InteropServices;
using DiskMap.Core.Native;

namespace DiskMap.Core;

/// <summary>
/// Sequential-output scanner: every directory's raw child listing is
/// parsed before its nodes are inserted, keeping memory proportional to
/// the tree plus one listing per in-flight directory.
///
/// Listing itself uses NtQueryDirectoryFile (FileIdBothDirectory-
/// Information, class 37 — the documented-stable class): one syscall per
/// page returns name, attributes, logical AND real on-disk AllocationSize,
/// creation and modification times, and the file id — everything
/// FindFirstFileExW returns plus the identity hard-link accounting needs,
/// with no extra call per file.
///
/// Directories list in parallel — several dozen at once, deliberately
/// unbounded: listing is IO-bound and the handle count stays small. A
/// denied listing keeps the scan going and records the directory id, so
/// the UI can say which totals are short.
///
/// Names of the same file (hard links) are detected by file id. Every
/// name keeps its recorded size in the tree; the rollup suppresses all
/// but the elected name — same rule as the MFT path and macOS.
/// </summary>
internal static class Win32Scanner
{
    /// <summary>Display name for the scan root — the folder's own name, or the drive root verbatim.</summary>
    internal static string RootName(string rootPath)
    {
        string trimmed = rootPath.TrimEnd('\\', '/');
        string? name = Path.GetFileName(trimmed);
        return string.IsNullOrEmpty(name) ? trimmed : name;
    }

    /// <summary>One parsed directory entry from a query page.</summary>
    internal readonly record struct Entry(
        string Name,
        uint Attributes,
        long LogicalSize,
        long AllocatedSize,
        int ModifiedDay,
        int CreatedDay,
        long FileId);

    /// <summary>A directory to list: node id, path, and its ancestor node directly under the scan root (-1 = this node's children are their own top-level).</summary>
    private readonly record struct Job(int NodeId, string Path, int TopLevelId);

    private sealed class State
    {
        internal readonly FileTree Tree;
        internal readonly Queue<Job> Jobs = new();
        internal int Inflight;
        internal bool Finished;
        internal int ItemCount;
        internal int NotDownloaded;
        internal int NoIdentity;
        internal readonly List<int> DeniedDirectoryIds = [];
        internal int FailedDirectories;
        internal ulong PeakResidentBytes;
        internal readonly long StartedTicks = System.Diagnostics.Stopwatch.GetTimestamp();
        internal readonly IProgress<ScanEngine.ScanProgress>? Progress;
        internal long LastReportTicks;
        internal readonly CancellationToken Cancellation;
        internal readonly int RootPathLength;
        /// <summary>fileId → first node id; a repeat flags both as HardLink.</summary>
        internal readonly Dictionary<long, int> FirstByFileId = new();
        /// <summary>Running own-bytes per top-level node — progress attribution.</summary>
        internal readonly Dictionary<int, long> TopBytes = new();
        internal string CurrentFolder = "";

        internal State(FileTree tree, IProgress<ScanEngine.ScanProgress>? progress,
            CancellationToken ct, int rootPathLength)
        {
            Tree = tree;
            Progress = progress;
            Cancellation = ct;
            RootPathLength = rootPathLength;
        }

        /// <summary>Emit the closing report even if the throttle window just fired.</summary>
        internal void ReportFinal()
        {
            LastReportTicks = 0;
            MaybeReport();
        }

        /// <summary>Emit a progress report at most every 250 ms.</summary>
        internal void MaybeReport()
        {
            long now = System.Diagnostics.Stopwatch.GetTimestamp();
            if (now - LastReportTicks < System.Diagnostics.Stopwatch.Frequency / 4) return;
            LastReportTicks = now;
            if (ProcessMemory.Current() is { } mem && mem.ResidentBytes > PeakResidentBytes)
                PeakResidentBytes = mem.ResidentBytes;
            if (Progress is null) return;
            var top = TopBytes.OrderByDescending(kv => kv.Value).Take(8)
                .Select(kv => (Name: Tree.NameOf(kv.Key), Bytes: kv.Value)).ToList();
            double seconds = System.Diagnostics.Stopwatch.GetElapsedTime(StartedTicks).TotalSeconds;
            string current = CurrentFolder.Length > RootPathLength + 1
                ? CurrentFolder[(RootPathLength + 1)..] : "";
            Progress.Report(new ScanEngine.ScanProgress(
                ItemCount, top.Sum(t => t.Bytes),
                seconds > 0 ? ItemCount / seconds : 0, current, top));
        }
    }

    /// <summary>
    /// Scans <paramref name="rootPath"/>. Returns null when
    /// <paramref name="headStart"/> runs out before the walk finishes
    /// (the caller then falls back to the MFT scan). A null headStart is
    /// an unbounded walk.
    /// </summary>
    internal static WalkResult? Walk(
        string rootPath, IProgress<ScanEngine.ScanProgress>? progress,
        TimeSpan? headStart, CancellationToken cancellationToken = default)
    {
        var tree = new FileTree();
        int rootId = tree.AddNode(RootName(rootPath).AsSpan(), -1, true, 0, 0, 0);
        var state = new State(tree, progress, cancellationToken, rootPath.TrimEnd('\\').Length);
        state.Jobs.Enqueue(new Job(rootId, rootPath, -1));
        state.Inflight = 1;

        int workers = Math.Max(4, Environment.ProcessorCount);
        var threads = new Thread[workers];
        var runStart = DateTime.UtcNow;
        for (int i = 0; i < workers; i++)
        {
            threads[i] = new Thread(() => Worker(state))
            {
                IsBackground = true,
                Name = $"diskmap-walk-{i}",
            };
            threads[i].Start();
        }

        // A real head start is just a deadline on the same queue.
        while (true)
        {
            if (cancellationToken.IsCancellationRequested) break;
            // The deadline wins over an already-finished queue: a caller
            // that asked for a head start gets null, not a result.
            if (headStart is { } budget && DateTime.UtcNow - runStart > budget) return null;
            bool done;
            lock (state.Jobs) done = state.Finished;
            if (done) break;
            Thread.Sleep(2);
        }
        foreach (var t in threads) t.Join();
        if (cancellationToken.IsCancellationRequested)
            cancellationToken.ThrowIfCancellationRequested();
        state.ReportFinal();
        return new WalkResult
        {
            Tree = state.Tree,
            ItemCount = state.ItemCount,
            NotDownloadedCount = state.NotDownloaded,
            PeakResidentBytesDuringWalk = state.PeakResidentBytes,
            Backend = "win32",
            DeniedDirectoryIds = state.DeniedDirectoryIds,
            FailedDirectoryCount = state.FailedDirectories,
            NoIdentityCount = state.NoIdentity,
        };
    }

    private static void Worker(State state)
    {
        var buffer = new byte[128 * 1024];
        while (true)
        {
            Job job;
            lock (state.Jobs)
            {
                if (state.Finished || state.Cancellation.IsCancellationRequested)
                {
                    state.Finished = true;
                    Monitor.PulseAll(state.Jobs);
                    return;
                }
                if (state.Jobs.Count == 0)
                {
                    // Poll so a cancelled scan doesn't park workers forever.
                    Monitor.Wait(state.Jobs, 100);
                    continue;
                }
                job = state.Jobs.Dequeue();
            }
            ScanDirectory(job, state, buffer);
        }
    }

    /// <summary>
    /// Field offsets inside one FILE_ID_BOTH_DIR_INFORMATION record —
    /// the common head (NextEntryOffset … FileNameLength) sits at the
    /// same place in every directory-information class; the FileId and
    /// FileName tail are what vary. Verified live; see Win32.cs.
    /// </summary>
    private const int NameLengthOffset = 60;
    private const int FileIdOffset = 96;
    private const int FileNameOffset = 104;

    private static unsafe void ScanDirectory(Job job, State state, byte[] buffer)
    {
        string dirPath = Win32.ExtendedPath(job.Path);
        using var handle = Win32.CreateFileW(
            dirPath,
            Win32.FILE_LIST_DIRECTORY | Win32.FILE_READ_ATTRIBUTES | Win32.SYNCHRONIZE,
            Win32.FILE_SHARE_READ | Win32.FILE_SHARE_WRITE | Win32.FILE_SHARE_DELETE,
            IntPtr.Zero, Win32.OPEN_EXISTING,
            Win32.FILE_FLAG_BACKUP_SEMANTICS | Win32.FILE_SYNCHRONOUS_IO_NONALERT,
            IntPtr.Zero);
        if (handle.IsInvalid)
        {
            state.NoteUnopenedDirectory(job, Marshal.GetLastWin32Error());
            return;
        }
        lock (state.Jobs) state.CurrentFolder = job.Path;

        var entries = new List<Entry>(256);
        bool failed = false;
        fixed (byte* p = buffer)
        {
            bool restart = true;
            while (true)
            {
                int status = Win32.NtQueryDirectoryFile(
                    handle, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero,
                    out _, p, buffer.Length, Win32.FileIdBothDirectoryInformation,
                    ReturnSingleEntry: false, IntPtr.Zero, RestartScan: restart);
                restart = false;
                if (status == Win32.STATUS_ACCESS_DENIED)
                {
                    state.NoteUnopenedDirectory(job, 0, ntStatus: status);
                    return;
                }
                if (status == Win32.STATUS_NO_MORE_FILES || status == Win32.STATUS_NO_SUCH_FILE
                    || status == Win32.STATUS_OBJECT_NAME_NOT_FOUND)
                {
                    break;  // end of listing (or an empty directory)
                }
                if (status != Win32.STATUS_SUCCESS)
                {
                    failed = true;
                    break;
                }

                int offset = 0;
                bool sane = true;
                while (true)
                {
                    var rec = new ReadOnlySpan<byte>(p + offset, buffer.Length - offset);
                    int next = I32(rec, 0);
                    int nameLength = I32(rec, NameLengthOffset);
                    if (nameLength < 0 || FileNameOffset + nameLength > rec.Length)
                    {
                        sane = false;
                        break;  // malformed page — stop trusting it
                    }
                    string name = System.Text.Encoding.Unicode.GetString(
                        rec.Slice(FileNameOffset, nameLength));
                    if (name is not ("." or ".."))
                    {
                        entries.Add(new Entry(
                            Name: name,
                            Attributes: (uint)I32(rec, 56),
                            LogicalSize: I64(rec, 40),
                            AllocatedSize: I64(rec, 48),
                            ModifiedDay: Win32.FileTimeToModifiedDay(I64(rec, 24)),
                            CreatedDay: Win32.FileTimeToModifiedDay(I64(rec, 8)),
                            FileId: I64(rec, FileIdOffset)));
                    }
                    if (next <= 0) break;
                    offset += next;
                }
                if (!sane) { failed = true; break; }
            }
        }
        state.Publish(job, entries, failed);

        static int I32(ReadOnlySpan<byte> rec, int at) =>
            System.Buffers.Binary.BinaryPrimitives.ReadInt32LittleEndian(rec[at..]);
        static long I64(ReadOnlySpan<byte> rec, int at) =>
            System.Buffers.Binary.BinaryPrimitives.ReadInt64LittleEndian(rec[at..]);
    }

    /// <summary>
    /// Inserts a completed listing's nodes and enqueues the child
    /// directories — always inside the same lock, so a dequeued-but-
    /// unpublished batch can never look like termination.
    /// </summary>
    private static void Publish(this State state, Job job, List<Entry> entries, bool failed)
    {
        lock (state.Jobs)
        {
            foreach (var e in entries)
            {
                var decision = ScanEngine.DecideFromAttributes(
                    e.Attributes, e.LogicalSize, e.AllocatedSize);
                if (!decision.Include) continue;
                byte flags = 0;
                if (decision.NotDownloaded)
                {
                    flags |= NodeFlags.NotDownloaded;
                    state.NotDownloaded++;
                }
                bool isDir = (e.Attributes & Win32.FILE_ATTRIBUTE_DIRECTORY) != 0;
                if (!isDir && e.FileId == 0) state.NoIdentity++;
                int nodeId = state.Tree.AddNode(
                    e.Name, job.NodeId, isDir,
                    decision.LogicalSize, decision.AllocatedSize,
                    e.ModifiedDay, flags, e.CreatedDay, e.FileId);
                state.ItemCount++;
                int top = job.TopLevelId == -1 ? nodeId : job.TopLevelId;
                state.TopBytes[top] = state.TopBytes.GetValueOrDefault(top) + decision.AllocatedSize;
                if (isDir && !decision.SkipDescendants)
                {
                    // Inflight counts enqueued-but-unpublished jobs; a
                    // publish can only ever be one job down.
                    state.Jobs.Enqueue(new Job(nodeId, job.Path + '\\' + e.Name, top));
                    state.Inflight++;
                }
                else if (!isDir && e.FileId != 0)
                {
                    if (state.FirstByFileId.TryGetValue(e.FileId, out int first))
                    {
                        state.Tree.AddFlags(first, NodeFlags.HardLink);
                        state.Tree.AddFlags(nodeId, NodeFlags.HardLink);
                    }
                    else
                    {
                        state.FirstByFileId[e.FileId] = nodeId;
                    }
                }
            }
            state.Inflight--;
            if (failed) state.FailedDirectories++;
            if (state.Inflight == 0 && state.Jobs.Count == 0) state.Finished = true;
            state.MaybeReport();
            Monitor.PulseAll(state.Jobs);
        }
    }

    /// <summary>
    /// A directory whose listing never ran — the node is already in the
    /// tree, so access-denied cases are reported against it while other
    /// failures are only counted.
    /// </summary>
    private static void NoteUnopenedDirectory(this State state, Job job, int error,
        int ntStatus = 0)
    {
        lock (state.Jobs)
        {
            bool denied = error is Win32.ERROR_ACCESS_DENIED or Win32.ERROR_NETWORK_ACCESS_DENIED
                || ntStatus == Win32.STATUS_ACCESS_DENIED;
            if (denied) state.DeniedDirectoryIds.Add(job.NodeId);
            // ERROR_FILE_NOT_FOUND / PATH_NOT_FOUND = raced deletion —
            // transient, not a failure worth reporting.
            else if (error is not (Win32.ERROR_FILE_NOT_FOUND or Win32.ERROR_PATH_NOT_FOUND)
                && ntStatus is not (Win32.STATUS_NO_SUCH_FILE or Win32.STATUS_OBJECT_NAME_NOT_FOUND))
                state.FailedDirectories++;
            state.Inflight--;
            if (state.Inflight == 0 && state.Jobs.Count == 0) state.Finished = true;
            Monitor.PulseAll(state.Jobs);
        }
    }
}
