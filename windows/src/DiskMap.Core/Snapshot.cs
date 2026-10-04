using System.Buffers.Binary;
using System.Text;

namespace DiskMap.Core;

public sealed record DiskSnapshot(string RootPath, DateTimeOffset CapturedAt, FileTree Tree);

public readonly record struct SnapshotChange(string Path, long Before, long After)
{
    public long Delta => After - Before;
}

/// <summary>
/// Snapshots are a versioned binary file, not SQLite — a scan is already
/// packed arrays plus an interned name table, and SQLite would be a second
/// data model for the same bytes.
///
/// The file is little-endian and byte-compatible with the macOS DMAP
/// format: magic "DMAP", version UInt32, timestamp seconds, root path,
/// node count, name-table count, then the packed arrays and the name
/// table. Version history (shared with the macOS codec):
///   v1: nameIndex/parent/firstChild/nextSibling/logical/allocated/
///       modifiedDay/isDirectory/flags
///   v2: + createdDay (Int32 per node)
///   v3: + fileID (UInt64 per node)
///   v4: + sharing-mode byte + sharing table (clone rows: node ids,
///       clone ids, private bytes, refcounts). Windows writes the same
///       layout when the opt-in ReFS block-clone pass ran (mode 2), and
///       decodes rows from either platform — the row semantics are
///       identical.
/// Older files decode with createdDay/fileID 0 ("unknown"); the hard-link
/// correction treats unknown as "nothing to correct".
/// </summary>
public static class SnapshotCodec
{
    public static readonly byte[] Magic = "DMAP"u8.ToArray();
    public const uint Version = 4;

    public static byte[] Encode(DiskSnapshot snapshot)
    {
        var tree = snapshot.Tree;
        var writer = new Writer();
        writer.Write(Magic);
        writer.U32(Version);
        writer.I64(snapshot.CapturedAt.ToUnixTimeSeconds());
        writer.String(snapshot.RootPath);
        writer.I32(tree.Count);
        writer.I32(tree.NameTable.Count);
        writer.I32s(tree.NameIndex);
        writer.I32s(tree.Parent);
        writer.I32s(tree.FirstChild);
        writer.I32s(tree.NextSibling);
        writer.I64s(tree.LogicalSize);
        writer.I64s(tree.AllocatedSize);
        writer.I32s(tree.ModifiedDay);
        writer.I32s(tree.CreatedDay);
        writer.Bytes(tree.IsDirectory.Select(b => (byte)(b ? 1 : 0)).ToArray());
        writer.Bytes(tree.Flags);
        writer.I64s(tree.FileId);
        // v4 sharing table: the mode byte records whether the block-clone
        // pass measured this tree (2 = full extent facts), not whether it
        // found clones — a profiled zero-clone scan still writes mode 2.
        var sharing = tree.Sharing;
        writer.Write([(byte)tree.SharingMode]);
        writer.I32(sharing.Count);
        writer.I32s(sharing.Node);
        writer.I64s(sharing.CloneId);
        writer.I64s(sharing.PrivateBytes);
        writer.I32s(sharing.RefCount);
        foreach (var name in tree.NameTable) writer.String(name);
        return writer.ToArray();
    }

    public static DiskSnapshot Decode(ReadOnlyMemory<byte> data)
    {
        var reader = new Reader(data);
        if (!reader.Bytes(4).Span.SequenceEqual(Magic)) throw new SnapshotException(SnapshotError.BadMagic);
        uint fileVersion = reader.U32();
        if (fileVersion < 1 || fileVersion > Version) throw new SnapshotException(SnapshotError.BadVersion);
        var capturedAt = DateTimeOffset.FromUnixTimeSeconds(reader.I64());
        string rootPath = reader.String();
        int count = reader.I32();
        int nameCount = reader.I32();
        if (count < 0 || nameCount < 0 || count >= 50_000_000 || nameCount >= 50_000_000)
            throw new SnapshotException(SnapshotError.Corrupt);
        int[] nameIndex = reader.I32s(count);
        int[] parent = reader.I32s(count);
        int[] firstChild = reader.I32s(count);
        int[] nextSibling = reader.I32s(count);
        long[] logicalSize = reader.I64s(count);
        long[] allocatedSize = reader.I64s(count);
        int[] modifiedDay = reader.I32s(count);
        int[] createdDay = fileVersion >= 2 ? reader.I32s(count) : new int[count];
        bool[] isDirectory = reader.U8s(count).Select(b => b != 0).ToArray();
        byte[] flags = reader.U8s(count);
        long[] fileId = fileVersion >= 3 ? reader.I64s(count) : new long[count];
        var sharing = new FileTree.SharingTable();
        var sharingMode = FileTree.CloneSharingMode.Off;
        if (fileVersion >= 4)
        {
            sharingMode = reader.U8s(1)[0] switch
            {
                1 => FileTree.CloneSharingMode.Refcount,
                2 => FileTree.CloneSharingMode.Full,
                _ => FileTree.CloneSharingMode.Off,
            };
            int rows = reader.I32();
            if (rows < 0 || rows > count) throw new SnapshotException(SnapshotError.Corrupt);
            sharing.Node = reader.I32s(rows);
            sharing.CloneId = reader.I64s(rows);
            sharing.PrivateBytes = reader.I64s(rows);
            sharing.RefCount = reader.I32s(rows);
        }
        var nameTable = new List<string>(nameCount);
        for (int i = 0; i < nameCount; i++) nameTable.Add(reader.String());

        var tree = new FileTree();
        if (!tree.ReplacePacked(nameTable, nameIndex, parent, firstChild, nextSibling,
                logicalSize, allocatedSize, modifiedDay, createdDay, isDirectory, flags, fileId))
        {
            throw new SnapshotException(SnapshotError.Corrupt);
        }
        // Rows carry macOS-APFS or Windows-ReFS facts identically — either
        // way the rollup's family math applies unchanged. Mode 0 means
        // "not measured": phantom rows under it are dropped, not trusted.
        if (sharingMode == FileTree.CloneSharingMode.Off) sharing = new FileTree.SharingTable();
        if (!tree.ReplaceSharing(sharing, sharingMode))
            throw new SnapshotException(SnapshotError.Corrupt);
        return new DiskSnapshot(rootPath, capturedAt, tree);
    }

    private sealed class Writer
    {
        private readonly MemoryStream _stream = new();
        private readonly BinaryWriter _writer;

        public Writer() => _writer = new BinaryWriter(_stream, Encoding.UTF8);

        public void Write(byte[] bytes) => _writer.Write(bytes);
        public void U32(uint v) => _writer.Write(v);
        public void I32(int v) => _writer.Write(v);
        public void I64(long v) => _writer.Write(v);
        public void I32s(IReadOnlyList<int> values) { foreach (int v in values) I32(v); }
        public void I64s(IReadOnlyList<long> values) { foreach (long v in values) I64(v); }
        public void Bytes(IReadOnlyList<byte> values) { foreach (byte v in values) _writer.Write(v); }
        public void String(string value)
        {
            byte[] bytes = Encoding.UTF8.GetBytes(value);
            U32((uint)bytes.Length);
            _writer.Write(bytes);
        }

        public byte[] ToArray() => _stream.ToArray();
    }

    private ref struct Reader
    {
        private readonly ReadOnlyMemory<byte> _data;
        private int _offset;

        public Reader(ReadOnlyMemory<byte> data) => _data = data;

        public ReadOnlyMemory<byte> Bytes(int count)
        {
            if (_offset + count > _data.Length) throw new SnapshotException(SnapshotError.Corrupt);
            var slice = _data.Slice(_offset, count);
            _offset += count;
            return slice;
        }

        public uint U32() => BinaryPrimitives.ReadUInt32LittleEndian(Bytes(4).Span);
        public int I32() => BinaryPrimitives.ReadInt32LittleEndian(Bytes(4).Span);
        public long I64() => BinaryPrimitives.ReadInt64LittleEndian(Bytes(8).Span);

        public int[] I32s(int count)
        {
            var result = new int[count];
            for (int i = 0; i < count; i++) result[i] = I32();
            return result;
        }

        public long[] I64s(int count)
        {
            var result = new long[count];
            for (int i = 0; i < count; i++) result[i] = I64();
            return result;
        }

        public byte[] U8s(int count) => Bytes(count).ToArray();

        public string String()
        {
            int count = (int)U32();
            if (count < 0 || count >= 10_000_000) throw new SnapshotException(SnapshotError.Corrupt);
            var bytes = Bytes(count);
            string value = Encoding.UTF8.GetString(bytes.Span);
            return value;
        }
    }
}

public sealed record SnapshotHeader(string RootPath, DateTimeOffset CapturedAt);

public static class SnapshotStore
{
    public static string DefaultDirectory()
    {
        string baseDir = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        return Path.Combine(baseDir, "DiskMap", "snapshots");
    }

    public static string Save(DiskSnapshot snapshot, string directory)
    {
        Directory.CreateDirectory(directory);
        string name = $"{snapshot.CapturedAt.ToUnixTimeSeconds()}-{Guid.NewGuid()}.snapshot";
        string path = Path.Combine(directory, name);
        // Atomic-ish write: write to temp then move, matching the macOS
        // .atomic write option's intent.
        string temp = path + ".tmp";
        File.WriteAllBytes(temp, SnapshotCodec.Encode(snapshot));
        File.Move(temp, path, overwrite: true);
        return path;
    }

    public static DiskSnapshot Load(string path) =>
        SnapshotCodec.Decode(File.ReadAllBytes(path));

    /// <summary>Header only — must not decode a million-node tree to show a date.</summary>
    public static SnapshotHeader ReadHeader(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        var buffer = new byte[Math.Min(65_536, stream.Length)];
        int read = stream.Read(buffer, 0, buffer.Length);
        var data = buffer.AsMemory(0, read);
        // Decode just the header prefix: magic, version, timestamp, rootPath.
        if (read < 20 || !data.Slice(0, 4).Span.SequenceEqual(SnapshotCodec.Magic))
            throw new SnapshotException(SnapshotError.BadMagic);
        uint version = BinaryPrimitives.ReadUInt32LittleEndian(data.Slice(4, 4).Span);
        if (version < 1 || version > SnapshotCodec.Version) throw new SnapshotException(SnapshotError.BadVersion);
        var capturedAt = DateTimeOffset.FromUnixTimeSeconds(BinaryPrimitives.ReadInt64LittleEndian(data.Slice(8, 8).Span));
        uint len = BinaryPrimitives.ReadUInt32LittleEndian(data.Slice(16, 4).Span);
        if (len > int.MaxValue || 20 + len > read) throw new SnapshotException(SnapshotError.Corrupt);
        string rootPath = Encoding.UTF8.GetString(data.Slice(20, (int)len).Span);
        return new SnapshotHeader(rootPath, capturedAt);
    }

    public static List<(string Path, SnapshotHeader Header)> Summaries(string directory, string rootPath)
    {
        if (!Directory.Exists(directory)) return [];
        var result = new List<(string, SnapshotHeader)>();
        foreach (var file in Directory.EnumerateFiles(directory, "*.snapshot"))
        {
            SnapshotHeader header;
            try { header = ReadHeader(file); }
            catch { continue; }
            if (header.RootPath == rootPath) result.Add((file, header));
        }
        return result.OrderBy(t => t.Item2.CapturedAt).ToList();
    }
}

public static class SnapshotDiff
{
    /// <summary>
    /// Folder size changes between two snapshots of the same root, largest
    /// absolute change first. A folder present on only one side is a full
    /// grow or shrink, not an omitted row.
    /// </summary>
    public static List<SnapshotChange> Changes(DiskSnapshot before, DiskSnapshot after, SizeBasis basis)
    {
        var left = FolderSizes(before, basis);
        var right = FolderSizes(after, basis);
        var paths = new HashSet<string>(left.Keys);
        paths.UnionWith(right.Keys);
        return paths
            .Select(p => new SnapshotChange(p, left.GetValueOrDefault(p), right.GetValueOrDefault(p)))
            .Where(c => c.Delta != 0)
            .OrderByDescending(c => Math.Abs(c.Delta))
            .ToList();
    }

    private static Dictionary<string, long> FolderSizes(DiskSnapshot snapshot, SizeBasis basis)
    {
        var totals = snapshot.Tree.RollUpSizes(basis);
        var sizes = new Dictionary<string, long>();
        if (snapshot.Tree.Count != totals.Length) return sizes;
        for (int id = 0; id < snapshot.Tree.Count; id++)
        {
            if (!snapshot.Tree.IsDirectory[id]) continue;
            string path = snapshot.Tree.PathOf(id, snapshot.RootPath);
            sizes[path] = totals[id];
        }
        return sizes;
    }
}

public enum SnapshotError { BadMagic, BadVersion, Corrupt }

public sealed class SnapshotException(SnapshotError error) : Exception(error.ToString())
{
    public SnapshotError Error { get; } = error;
}
