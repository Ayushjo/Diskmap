using DiskMap.Core.Native;

namespace DiskMap.Core;

/// <summary>
/// Resident memory of this process via GetProcessMemoryInfo
/// (PROCESS_MEMORY_COUNTERS_EX) — the same fields Task Manager's
/// "Memory" column is derived from, without eyeballing the UI.
/// </summary>
public readonly record struct ProcessMemory(ulong ResidentBytes, ulong PeakResidentBytes, ulong VirtualBytes)
{
    public static ProcessMemory? Current()
    {
        var info = new Win32.PROCESS_MEMORY_COUNTERS_EX { cb = (uint)System.Runtime.InteropServices.Marshal.SizeOf<Win32.PROCESS_MEMORY_COUNTERS_EX>() };
        if (!Win32.GetProcessMemoryInfo(Win32.GetCurrentProcess(), out info, info.cb))
            return null;
        return new ProcessMemory(
            (ulong)info.WorkingSetSize,
            (ulong)info.PeakWorkingSetSize,
            (ulong)info.PrivateUsage);
    }
}
