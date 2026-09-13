import Darwin

/// Resident memory of this process, read from the kernel via
/// `task_info(MACH_TASK_BASIC_INFO)` — the same fields Activity Monitor's
/// "Memory" column is derived from, without eyeballing the UI.
///
/// `peakResidentBytes` is `mach_task_basic_info.resident_size_max`: the
/// high-water mark of resident memory since this process started, in
/// bytes. Confirmed against the active SDK's `<mach/task_info.h>`
/// (`MACH_TASK_BASIC_INFO` is 20; `resident_size_max` is the third field).
public struct ProcessMemory: Sendable, Equatable {
    public var residentBytes: UInt64
    public var peakResidentBytes: UInt64
    public var virtualBytes: UInt64

    public static func current() -> ProcessMemory? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.stride / MemoryLayout<natural_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return ProcessMemory(
            residentBytes: UInt64(info.resident_size),
            peakResidentBytes: UInt64(info.resident_size_max),
            virtualBytes: UInt64(info.virtual_size)
        )
    }
}
