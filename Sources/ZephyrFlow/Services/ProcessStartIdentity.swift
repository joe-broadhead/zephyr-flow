import Darwin

/// One representation for capture and insertion revalidation. libproc reports
/// epoch seconds/microseconds, NOT uptime. Keep the integer identity exact;
/// converting NSRunningApplication.launchDate through Double loses precision.
enum ProcessStartIdentity {
    static func read(pid: Int32) -> UInt64? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let returned = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size))
        guard returned == Int32(size), info.pbi_pid == UInt32(pid) else { return nil }
        return nanoseconds(seconds: UInt64(info.pbi_start_tvsec), microseconds: UInt64(info.pbi_start_tvusec))
    }

    static func nanoseconds(seconds: UInt64, microseconds: UInt64) -> UInt64? {
        guard microseconds < 1_000_000 else { return nil }
        let (whole, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !overflow else { return nil }
        let (result, additionOverflow) = whole.addingReportingOverflow(microseconds * 1_000)
        guard !additionOverflow, result > 0 else { return nil }
        return result
    }
}
