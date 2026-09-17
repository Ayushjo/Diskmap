using DiskMap.Core.Native;

namespace DiskMap.Core;

/// <summary>
/// Fallback directory walk using FindFirstFileExW — the direct Windows
/// equivalent of getattrlistbulk: one call per directory returns a page of
/// names, types, sizes, and mtimes (FindExInfoBasic + LARGE_FETCH batching).
/// No per-file stat calls, except for compressed/sparse files where
/// GetCompressedFileSizeW is needed for the real on-disk size.
///
/// Used when the MFT path is unavailable: non-NTFS volumes, non-elevated
/// runs, network drives.
/// </summary>
internal static class Win32Scanner
{
    private readonly record struct Job(string Path, int NodeId);

    public static WalkResult Walk(string root, IProgress<int>? progress)
    {
        var tree = new FileTree();
        int rootId = tree.AddNode(
            name: RootName(root), parentId: -1, isDirectory: true,
            logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0);
        long clusterSize = ClusterSize(root);
        var state = new State(tree, progress);
        state.Enqueue(root, rootId);

        int workers = Math.Max(1, Math.Min(8, Environment.ProcessorCount));
        var threads = new Task[workers];
        for (int i = 0; i < workers; i++)
            threads[i] = Task.Run(() => Worker(state, clusterSize));
        Task.WaitAll(threads);
        return state.Finish();
    }

    private static void Worker(State state, long clusterSize)
    {
        while (state.NextJob() is { } job)
            ScanDirectory(job, state, clusterSize);
    }

    private static void ScanDirectory(Job job, State state, long clusterSize)
    {
        string pattern = Win32.ExtendedPath(job.Path) + @"\*";
        using var handle = Win32.FindFirstFileExW(
            pattern, Win32.FindExInfoBasic, out var data,
            Win32.FindExSearchNameMatch, IntPtr.Zero, Win32.FIND_FIRST_EX_LARGE_FETCH);
        if (handle.IsInvalid)
        {
            state.NoteEmptyDirectory();
            return;
        }

        var entries = new List<Entry>(256);
        do
        {
            ReadOnlySpan<char> name = NameOf(in data);
            if (name.SequenceEqual(".".AsSpan()) || name.SequenceEqual("..".AsSpan()))
                continue;
            entries.Add(MakeEntry(name.ToString(), job.Path, in data, clusterSize));
        } while (Win32.FindNextFileW(handle, out data));

        state.Publish(job, entries);
    }

    private static unsafe ReadOnlySpan<char> NameOf(in Win32.WIN32_FIND_DATAW data)
    {
        fixed (char* p = data.cFileName)
        {
            var span = new ReadOnlySpan<char>(p, 260);
            int end = span.IndexOf('\0');
            return end < 0 ? span : span[..end];
        }
    }

    private static Entry MakeEntry(string name, string parentPath, in Win32.WIN32_FIND_DATAW data, long clusterSize)
    {
        bool isDir = (data.dwFileAttributes & Win32.FILE_ATTRIBUTE_DIRECTORY) != 0;
        long logical = isDir ? 0 : ((long)data.nFileSizeHigh << 32) | data.nFileSizeLow;
        long allocated = isDir ? 0 : AllocatedSize(parentPath, name, data.dwFileAttributes, logical, clusterSize);
        var decision = ScanEngine.DecideFromAttributes(data.dwFileAttributes, logical, allocated);
        return new Entry(
            Name: name,
            Include: decision.Include,
            IsDirectory: isDir,
            Logical: decision.LogicalSize,
            Allocated: decision.AllocatedSize,
            Day: Win32.FileTimeToModifiedDay(data.ftLastWriteTime),
            NotDownloaded: decision.NotDownloaded,
            Descend: isDir && !decision.SkipDescendants);
    }

    /// <summary>
    /// On-disk size: compressed/sparse files need GetCompressedFileSizeW;
    /// everything else is logical size rounded up to a cluster.
    /// </summary>
    private static long AllocatedSize(string parentPath, string name, uint attributes, long logical, long clusterSize)
    {
        const uint needsQuery = Win32.FILE_ATTRIBUTE_COMPRESSED | Win32.FILE_ATTRIBUTE_SPARSE_FILE;
        if ((attributes & needsQuery) != 0)
        {
            string path = Win32.ExtendedPath(Path.Combine(parentPath, name));
            uint low = Win32.GetCompressedFileSizeW(path, out uint high);
            if (low != 0xFFFFFFFF)
                return ((long)high << 32) | low;
            // fall through to rounding on failure
        }
        if (logical == 0) return 0;
        return (logical + clusterSize - 1) / clusterSize * clusterSize;
    }

    private static long ClusterSize(string root)
    {
        string? rootPath = Path.GetPathRoot(root);
        if (rootPath is not null
            && Win32.GetDiskFreeSpaceW(rootPath, out uint sectors, out uint bytes, out _, out _)
            && sectors > 0 && bytes > 0)
        {
            return (long)sectors * bytes;
        }
        return 4096;
    }

    internal static string RootName(string root)
    {
        string trimmed = root.TrimEnd(Path.DirectorySeparatorChar);
        string name = Path.GetFileName(trimmed);
        return string.IsNullOrEmpty(name) ? trimmed : name;
    }

    private sealed class State
    {
        private readonly object _gate = new();
        private readonly Queue<Job> _jobs = new();
        private readonly Dictionary<int, string> _pathByNode = new();
        private int _inflight;
        private bool _finished;
        private int _itemCount;
        private int _notDownloadedCount;
        private int _lastReported;
        private ulong _peak;
        private readonly IProgress<int>? _progress;
        public readonly FileTree Tree;

        public State(FileTree tree, IProgress<int>? progress)
        {
            Tree = tree;
            _progress = progress;
            _peak = ProcessMemory.Current()?.ResidentBytes ?? 0;
        }

        public void Enqueue(string path, int nodeId)
        {
            lock (_gate)
            {
                _pathByNode[nodeId] = path;
                _jobs.Enqueue(new Job(path, nodeId));
                Monitor.PulseAll(_gate);
            }
        }

        public Job? NextJob()
        {
            lock (_gate)
            {
                while (_jobs.Count == 0 && !_finished)
                    Monitor.Wait(_gate);
                if (_jobs.Count == 0) return null;
                _inflight++;
                return _jobs.Dequeue();
            }
        }

        public void NoteEmptyDirectory()
        {
            lock (_gate)
            {
                _inflight--;
                if (_jobs.Count == 0 && _inflight == 0)
                {
                    _finished = true;
                    Monitor.PulseAll(_gate);
                }
            }
        }

        public void Publish(Job parentJob, List<Entry> entries)
        {
            var children = new List<(string Path, int NodeId)>();
            int report = -1;
            lock (_gate)
            {
                _itemCount += entries.Count;
                if (_itemCount - _lastReported >= 4000)
                {
                    _lastReported = _itemCount;
                    report = _itemCount;
                }
                foreach (var entry in entries)
                {
                    if (!entry.Include) continue;
                    byte flags = 0;
                    if (entry.NotDownloaded)
                    {
                        flags |= NodeFlags.NotDownloaded;
                        _notDownloadedCount++;
                    }
                    int id = Tree.AddNode(
                        entry.Name.AsSpan(), parentId: parentJob.NodeId,
                        isDirectory: entry.IsDirectory, logicalSize: entry.Logical,
                        allocatedSize: entry.Allocated, modifiedDaysSinceEpoch: entry.Day,
                        flags: flags);
                    if (entry.Descend)
                    {
                        string path = Path.Join(parentJob.Path, entry.Name);
                        _pathByNode[id] = path;
                        children.Add((path, id));
                    }
                }
                foreach (var (path, id) in children)
                    _jobs.Enqueue(new Job(path, id));
                _inflight--;
                if (children.Count > 0) Monitor.PulseAll(_gate);
                if (_jobs.Count == 0 && _inflight == 0)
                {
                    _finished = true;
                    Monitor.PulseAll(_gate);
                }
            }
            if (report >= 0)
            {
                if (ProcessMemory.Current() is { } mem && mem.ResidentBytes > _peak)
                    lock (_gate) { if (mem.ResidentBytes > _peak) _peak = mem.ResidentBytes; }
                _progress?.Report(report);
            }
        }

        public WalkResult Finish()
        {
            lock (_gate)
            {
                ulong now = ProcessMemory.Current()?.ResidentBytes ?? _peak;
                return new WalkResult
                {
                    Tree = Tree,
                    ItemCount = _itemCount,
                    NotDownloadedCount = _notDownloadedCount,
                    PeakResidentBytesDuringWalk = Math.Max(_peak, now),
                    Backend = "win32",
                };
            }
        }
    }

    private sealed record Entry(
        string Name,
        bool Include,
        bool IsDirectory,
        long Logical,
        long Allocated,
        int Day,
        bool NotDownloaded,
        bool Descend);
}
