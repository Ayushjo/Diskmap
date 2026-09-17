using DiskMap.Core.Native;
using Xunit.Abstractions;

namespace DiskMap.Core.Tests;

public class NativeProbeTests(ITestOutputHelper output)
{
    [Fact]
    public unsafe void EnumerateKnownDirectory()
    {
        string dir = Path.Combine(Path.GetTempPath(), $"dm-probe-{Guid.NewGuid()}");
        Directory.CreateDirectory(dir);
        File.WriteAllText(Path.Combine(dir, "alpha.txt"), "x");
        File.WriteAllText(Path.Combine(dir, "beta.txt"), "y");
        Directory.CreateDirectory(Path.Combine(dir, "subdir"));

        using var handle = Win32.FindFirstFileExW(
            Win32.ExtendedPath(dir) + @"\*", Win32.FindExInfoBasic, out var data,
            Win32.FindExSearchNameMatch, IntPtr.Zero, Win32.FIND_FIRST_EX_LARGE_FETCH);
        Assert.False(handle.IsInvalid, "FindFirstFileExW failed");

        int i = 0;
        do
        {
            string name;
            char* p = data.cFileName;
            var span = new ReadOnlySpan<char>(p, 260);
            int end = span.IndexOf('\0');
            name = (end < 0 ? span : span[..end]).ToString();
            output.WriteLine($"[{i}] attrs=0x{data.dwFileAttributes:X8} size={data.nFileSizeHigh:X8}:{data.nFileSizeLow:X8} name='{name}'");
            i++;
            if (i > 10) break;
        } while (Win32.FindNextFileW(handle, out data));

        Directory.Delete(dir, true);
    }
}
