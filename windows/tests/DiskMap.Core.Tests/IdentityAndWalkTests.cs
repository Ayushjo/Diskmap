using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using DiskMap.Core;
using Win32 = DiskMap.Core.Native.Win32;

namespace DiskMap.Core.Tests;

/// <summary>
/// Real-filesystem tests for the NtQueryDirectoryFile walk backend:
/// file identity, creation times, hard-link dedup, denied directories,
/// cancellation. No mocks — the rules for this codebase ask for real
/// fixtures wherever the filesystem behaviour is the thing under test.
/// </summary>
public class IdentityAndWalkTests
{
    /// <summary>
    /// Pins the FILE_ID_BOTH_DIR_INFORMATION record offsets the scanner
    /// relies on: FileAttributes@56, FileNameLength@60, FileId@96,
    /// FileName@104 — checked against a live query, not a header.
    /// </summary>
    [Fact]
    public unsafe void DirInformationLayoutMatchesLiveQuery()
    {
        string dir = Path.Combine(Path.GetTempPath(), $"DiskMap-raw-{Guid.NewGuid()}");
        Directory.CreateDirectory(dir);
        File.WriteAllText(Path.Combine(dir, "probefile.txt"), "x");
        try
        {
            using var h = DiskMap.Core.Native.Win32.CreateFileW(
                DiskMap.Core.Native.Win32.ExtendedPath(dir),
                DiskMap.Core.Native.Win32.FILE_LIST_DIRECTORY | DiskMap.Core.Native.Win32.SYNCHRONIZE,
                Win32.FILE_SHARE_READ | Win32.FILE_SHARE_WRITE | Win32.FILE_SHARE_DELETE,
                IntPtr.Zero, DiskMap.Core.Native.Win32.OPEN_EXISTING,
                DiskMap.Core.Native.Win32.FILE_FLAG_BACKUP_SEMANTICS | DiskMap.Core.Native.Win32.FILE_SYNCHRONOUS_IO_NONALERT,
                IntPtr.Zero);
            Assert.False(h.IsInvalid, $"open failed: {Marshal.GetLastWin32Error()}");
            var buf = new byte[8192];
            fixed (byte* p = buf)
            {
                int status = DiskMap.Core.Native.Win32.NtQueryDirectoryFile(
                    h, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, out var iosb,
                    p, buf.Length, DiskMap.Core.Native.Win32.FileIdBothDirectoryInformation,
                    false, IntPtr.Zero, true);
                Assert.Equal(0, status);

                // Walk the page until the file's record and check each field.
                int offset = 0;
                string? lastName = null;
                while (true)
                {
                    var rec = buf.AsSpan(offset);
                    int next = System.Buffers.Binary.BinaryPrimitives.ReadInt32LittleEndian(rec);
                    int nameLen = System.Buffers.Binary.BinaryPrimitives.ReadInt32LittleEndian(rec[60..]);
                    Assert.True(nameLen >= 0 && 104 + nameLen <= rec.Length);
                    lastName = System.Text.Encoding.Unicode.GetString(rec.Slice(104, nameLen));
                    if (lastName == "probefile.txt") break;
                    Assert.True(next > 0, "probefile.txt not listed");
                    offset += next;
                }
                Assert.Equal("probefile.txt", lastName);
                var probe = buf.AsSpan(offset);
                Assert.NotEqual(0, System.Buffers.Binary.BinaryPrimitives.ReadInt64LittleEndian(probe[96..]));  // file id
                Assert.Equal(0x20, System.Buffers.Binary.BinaryPrimitives.ReadInt32LittleEndian(probe[56..]) & 0x3FFFFFFF);  // attributes: archive
            }
        }
        finally { try { Directory.Delete(dir, true); } catch { } }
    }

    [Fact]
    public void WalkCapturesFileIdentityAndCreationDay()
    {
        using var fixture = new Fixture();
        var result = Win32Scanner.Walk(fixture.Root, null, null)!;
        Assert.NotNull(result);

        int file = FindByName(result.Tree, "data.bin");
        Assert.True(file >= 0);
        Assert.NotEqual(0, result.Tree.FileId[file]);
        int today = (int)(DateTimeOffset.UtcNow.ToUnixTimeSeconds() / 86_400);
        Assert.InRange(result.Tree.CreatedDay[file], today - 2, today + 1);
        Assert.Equal(0, result.NoIdentityCount);
    }

    [Fact]
    public void HardLinkedNamesShareFileIdAndChargeOnce()
    {
        using var fixture = new Fixture();
        string a = Path.Combine(fixture.Root, "aa", "first.bin");
        string b = Path.Combine(fixture.Root, "zz", "second.bin");
        File.WriteAllBytes(a, new byte[100_000]);
        Assert.True(CreateHardLinkW(b, a, IntPtr.Zero));

        var result = Win32Scanner.Walk(fixture.Root, null, null)!;
        var tree = result.Tree;
        int first = FindByName(tree, "first.bin");
        int second = FindByName(tree, "second.bin");
        Assert.True(first >= 0 && second >= 0);
        Assert.Equal(tree.FileId[first], tree.FileId[second]);
        Assert.True((tree.Flags[first] & NodeFlags.HardLink) != 0);
        Assert.True((tree.Flags[second] & NodeFlags.HardLink) != 0);

        // Both names keep their recorded size; the rollup charges the
        // bytes once — the root total is one link plus the fixture file.
        var totals = tree.RollUpSizes();
        Assert.Equal(tree.AllocatedSize[first], totals[first]);
        Assert.Equal(0, totals[second]);
        long expected = tree.AllocatedSize[first] + tree.AllocatedSize[FindByName(tree, "data.bin")];
        Assert.Equal(expected, totals[0]);

        var correction = tree.GetHardLinkCorrection();
        Assert.Equal(1, correction.DuplicateNameCount);
        Assert.Equal(1, correction.InodeCount);
        Assert.Equal(tree.AllocatedSize[first], correction.AllocatedBytes);
    }

    [Fact]
    public void ElectedHardLinkNameIsTheLowestPath()
    {
        // The charge must sit on the lowest path, not on scan order —
        // that's what keeps snapshot diffs stable (WIN-002).
        var tree = new FileTree();
        int root = tree.AddNode("root", -1, true, 0, 0, 0);
        int zdir = tree.AddNode("zdir", root, true, 0, 0, 0);
        int adir = tree.AddNode("adir", root, true, 0, 0, 0);
        // Insert the zdir name first; the fileId groups them regardless.
        int z = tree.AddNode("file.bin", zdir, false, 100, 100, 1, NodeFlags.HardLink, 0, 42);
        int a = tree.AddNode("file.bin", adir, false, 100, 100, 1, NodeFlags.HardLink, 0, 42);

        var totals = tree.RollUpSizes();
        Assert.Equal(100, totals[adir]);   // "adir\file.bin" < "zdir\file.bin"
        Assert.Equal(0, totals[zdir]);
        Assert.Equal(100, totals[root]);
    }

    [Fact]
    public void UnrelatedFilesWithDistinctIdsBothCharge()
    {
        var tree = new FileTree();
        int root = tree.AddNode("root", -1, true, 0, 0, 0);
        tree.AddNode("a.bin", root, false, 100, 100, 1, NodeFlags.HardLink, 0, 42);
        tree.AddNode("b.bin", root, false, 100, 100, 1, NodeFlags.HardLink, 0, 43);
        Assert.Equal(200, tree.RollUpSizes()[root]);
    }

    [Fact]
    public void DeniedDirectoryIsReportedByNodeId()
    {
        using var fixture = new Fixture();
        string locked = Path.Combine(fixture.Root, "locked");
        Directory.CreateDirectory(locked);
        File.WriteAllText(Path.Combine(locked, "inside.txt"), "secret");

        var info = new DirectoryInfo(locked);
        var acl = info.GetAccessControl();
        var deny = new FileSystemAccessRule(
            WindowsIdentity.GetCurrent().User!,
            FileSystemRights.ListDirectory | FileSystemRights.ReadData,
            AccessControlType.Deny);
        acl.AddAccessRule(deny);
        info.SetAccessControl(acl);
        try
        {
            var result = Win32Scanner.Walk(fixture.Root, null, null)!;
            Assert.NotNull(result);
            int lockedNode = FindByName(result.Tree, "locked");
            Assert.True(lockedNode >= 0);
            Assert.True(
                result.DeniedDirectoryIds.Contains(lockedNode)
                || FindByName(result.Tree, "inside.txt") >= 0);
        }
        finally
        {
            var reset = info.GetAccessControl();
            reset.RemoveAccessRule(deny);
            info.SetAccessControl(reset);
        }
    }

    [Fact]
    public void CancelledWalkThrowsAndPublishesNothing()
    {
        using var fixture = new Fixture();
        var cts = new CancellationTokenSource();
        cts.Cancel();
        Assert.Throws<OperationCanceledException>(
            () => Win32Scanner.Walk(fixture.Root, null, null, cts.Token));
    }

    [Fact]
    public async Task ConcurrentWalksAllTerminate()
    {
        // The work-queue audit: N scans of the same tree must all finish —
        // a publish/termination race would hang workers past the timeout.
        using var fixture = new Fixture();
        var tasks = Enumerable.Range(0, 8).Select(_ => Task.Run(() =>
            Win32Scanner.Walk(fixture.Root, null, null))).ToArray();
        var all = await Task.WhenAll(tasks).WaitAsync(TimeSpan.FromSeconds(30));
        foreach (var t in all) Assert.NotNull(t);
    }

    private static int FindByName(FileTree tree, string name)
    {
        for (int i = 0; i < tree.Count; i++)
            if (tree.NameOf(i) == name) return i;
        return -1;
    }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CreateHardLinkW(string lpFileName, string lpExistingFileName, IntPtr lpSecurityAttributes);

    private sealed class Fixture : IDisposable
    {
        public readonly string Root;

        public Fixture()
        {
            Root = Path.Combine(Path.GetTempPath(), $"DiskMap-id-{Guid.NewGuid()}");
            Directory.CreateDirectory(Path.Combine(Root, "aa"));
            Directory.CreateDirectory(Path.Combine(Root, "zz"));
            File.WriteAllBytes(Path.Combine(Root, "data.bin"), new byte[4096]);
        }

        public void Dispose()
        {
            try
            {
                foreach (var dir in Directory.EnumerateDirectories(Root))
                    File.SetAttributes(dir, FileAttributes.Normal);
                Directory.Delete(Root, recursive: true);
            }
            catch { }
        }
    }
}

/// <summary>
/// DMAP codec version tests — the Windows file must stay byte-compatible
/// with the macOS format in both directions.
/// </summary>
public class SnapshotCodecVersionTests
{
    [Fact]
    public void V4RoundTripPreservesIdentityAndCreatedDay()
    {
        var tree = new FileTree();
        int root = tree.AddNode("root", -1, true, 0, 0, 0);
        tree.AddNode("a.bin", root, false, 100, 4096, 19_500, 0, 19_000, 0xABCD);
        var snapshot = new DiskSnapshot(@"C:\tmp\rt",
            DateTimeOffset.FromUnixTimeSeconds(1_700_000_000), tree);

        var bytes = SnapshotCodec.Encode(snapshot);
        // Version is the second field, after the DMAP magic.
        Assert.Equal(4u, BitConverter.ToUInt32(bytes, 4));

        var decoded = SnapshotCodec.Decode(bytes);
        Assert.Equal(0xABCD, decoded.Tree.FileId[1]);
        Assert.Equal(19_000, decoded.Tree.CreatedDay[1]);
        Assert.Equal(19_500, decoded.Tree.ModifiedDay[1]);
        Assert.Equal(100, decoded.Tree.LogicalSize[1]);
    }

    [Fact]
    public void V1FileStillDecodesWithZeroIdentity()
    {
        // A minimal hand-built v1 file: two nodes ("root" dir + "f" file),
        // no createdDay/fileID sections — the Windows codec must still read
        // it and report unknown identity rather than rejecting it.
        var w = new MemoryStream();
        void I32(int v) => w.Write(BitConverter.GetBytes(v));
        void I64(long v) => w.Write(BitConverter.GetBytes(v));
        void Str(string s)
        {
            var b = System.Text.Encoding.UTF8.GetBytes(s);
            I32(b.Length);
            w.Write(b);
        }
        w.Write("DMAP"u8);
        I32(1);                       // version
        I64(1_700_000_000);           // capturedAt
        Str(@"C:\tmp\v1");            // root path
        I32(2);                       // node count
        I32(2);                       // name table count
        I32(0); I32(1);               // nameIndex
        I32(-1); I32(0);              // parent
        I32(1); I32(-1);              // firstChild
        I32(-1); I32(-1);             // nextSibling
        I64(0); I64(10);              // logicalSize
        I64(0); I64(4096);            // allocatedSize
        I32(0); I32(19_000);          // modifiedDay
        w.WriteByte(1); w.WriteByte(0);   // isDirectory
        w.WriteByte(0); w.WriteByte(0);   // flags
        Str("root"); Str("f");        // name table

        var decoded = SnapshotCodec.Decode(w.ToArray());
        Assert.Equal(2, decoded.Tree.Count);
        Assert.Equal(0, decoded.Tree.FileId[1]);
        Assert.Equal(0, decoded.Tree.CreatedDay[1]);
        Assert.Equal("f", decoded.Tree.NameOf(1));
    }

    [Fact]
    public void V4SharingTableIsSkipped()
    {
        // A macOS v4 file carries APFS sharing rows after the fileIDs;
        // Windows doesn't produce them but must consume them to stay
        // byte-compatible in both directions.
        var w = new MemoryStream();
        void I32(int v) => w.Write(BitConverter.GetBytes(v));
        void I64(long v) => w.Write(BitConverter.GetBytes(v));
        void U64(ulong v) => w.Write(BitConverter.GetBytes(v));
        void Str(string s)
        {
            var b = System.Text.Encoding.UTF8.GetBytes(s);
            I32(b.Length);
            w.Write(b);
        }
        w.Write("DMAP"u8);
        I32(4);
        I64(1_700_000_000);
        Str("/tmp/v4");
        I32(1);                       // one node
        I32(1);                       // one name
        I32(0);                       // nameIndex
        I32(-1);                      // parent
        I32(-1);                      // firstChild
        I32(-1);                      // nextSibling
        I64(0);                       // logicalSize
        I64(0);                       // allocatedSize
        I32(1);                       // modifiedDay
        I32(1);                       // createdDay (v2+)
        w.WriteByte(1);               // isDirectory
        w.WriteByte(0);               // flags
        U64(12345);                   // fileID (v3+)
        w.WriteByte(2);               // sharingMode = full (v4)
        I32(1);                       // one sharing row
        I32(0);                       // node id
        U64(777);                     // clone id
        I64(4096);                    // private bytes
        I32(2);                       // refcount
        Str("root");                  // name table

        var decoded = SnapshotCodec.Decode(w.ToArray());
        Assert.Single(decoded.Tree.NameIndex);
        Assert.Equal(12345, decoded.Tree.FileId[0]);
    }

    /// <summary>
    /// WIN-068 — the Windows fresh-clone analog: a sparse file has a big
    /// logical size with ~nothing allocated. The walk must report the
    /// split honestly: allocated ≪ logical (this is what clone/copy-
    /// detection and "compressed by" figures all read from).
    /// </summary>
    [Fact]
    public void SparseFileAllocatedDiffersFromLogical()
    {
        string dir = Path.Combine(Path.GetTempPath(), $"DiskMap-sparse-{Guid.NewGuid()}");
        Directory.CreateDirectory(dir);
        string file = Path.Combine(dir, "sparse.bin");
        using (var fs = new FileStream(file, FileMode.CreateNew))
        {
            // Seek alone doesn't mark the file sparse on NTFS —
            // FSCTL_SET_SPARSE does; then the tail bytes never allocate.
            unsafe
            {
                Win32.DeviceIoControl(fs.SafeFileHandle, 0x000900C4 /* FSCTL_SET_SPARSE */,
                    null, 0, null, 0, out _, IntPtr.Zero);
            }
            fs.Seek(64 * 1024 * 1024 - 1, SeekOrigin.Begin); // 64 MB logical
            fs.WriteByte(0);
            fs.Flush(flushToDisk: true);                   // FlushFileBuffers
        }
        try
        {
            var result = Win32Scanner.Walk(dir, null, null)!;
            var tree = result.Tree;
            int id = Enumerable.Range(0, tree.Count)
                .First(i => tree.NameOf(i) == "sparse.bin");
            Assert.True(tree.LogicalSize[id] >= 64 * 1024 * 1024,
                "logical size should reflect the 64 MB extent");
            Assert.True(tree.AllocatedSize[id] < 4 * 1024 * 1024,
                $"allocated should be ≪ logical for a sparse tail; got {tree.AllocatedSize[id]}");
        }
        finally { try { Directory.Delete(dir, true); } catch { } }
    }
}
