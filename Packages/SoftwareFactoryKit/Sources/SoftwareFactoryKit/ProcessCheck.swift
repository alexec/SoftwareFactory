#if canImport(Darwin)
import Darwin
#endif
import Foundation

/// Whether a process is still running, answered properly rather than guessed at.
///
/// The factory had three ways to guess and none to know. `isConnected` is only cleared
/// when a client says goodbye, so an agent that crashed stays connected for ever and one
/// that is merely quiet looks the same as one that has gone. Matching on the launch
/// command line breaks the moment an agent is resumed, because a resumed agent has no
/// launch wrapper. Silence is not an exit: an agent thinking, building or waiting on the
/// person is silent too, which is why the factory used to wait an hour before it decided.
///
/// A process id settles it, as long as it is not asked on its own. Process ids are
/// recycled, so a pid that answers might be somebody else's process wearing a dead
/// agent's number. Recording when the process started closes that: a recycled pid cannot
/// also have started at the same instant. (Alex, 13 Sep 2026: specifically, we need to
/// associate the PID to the agent.)
public enum ProcessCheck {
    /// When this process started, or nil if there is no such process. Local only: this
    /// asks the kernel about a process on this machine.
    public static func startTime(of pid: Int32) -> Date? {
        #if canImport(Darwin)
        guard pid > 0 else { return nil }
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let ok = name.withUnsafeMutableBufferPointer { buffer in
            sysctl(buffer.baseAddress, u_int(buffer.count), &info, &size, nil, 0) == 0
        }
        // A pid nobody is using answers with a zeroed record rather than an error, so the
        // pid it reports back has to match the one that was asked for.
        guard ok, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let started = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000)
        #else
        return nil
        #endif
    }

    /// Stops the process recorded for an agent, and answers whether it had one to stop.
    ///
    /// The pair is checked first and the whole point of checking it is here rather than
    /// in the reading: a pid on its own is recycled, and signalling one on its own is how
    /// you kill somebody else's work. Nothing is sent unless the process running under
    /// that pid is the one that started when the agent's record says it started.
    ///
    /// SIGTERM, so the agent gets to put its own things down. An agent that ignores it is
    /// still there afterwards, and `isRunning` will say so: stopping harder is the
    /// caller's next move, not a decision to make inside one call. (T261.)
    @discardableResult
    public static func stop(pid: Int32?, startedAt: Date?, signal code: Int32 = SIGTERM) -> Bool {
        #if canImport(Darwin)
        guard let pid, isRunning(pid: pid, startedAt: startedAt) else { return false }
        return kill(pid, code) == 0
        #else
        return false
        #endif
    }

    /// Whether the process recorded for an agent is the one still running. Both halves
    /// are needed: the pid says where to look and the start time says it is still the
    /// same process. A second's tolerance, because the two clocks are not the same one.
    public static func isRunning(pid: Int32?, startedAt: Date?) -> Bool {
        guard let pid, let startedAt, let now = startTime(of: pid) else { return false }
        return abs(now.timeIntervalSince(startedAt)) < 1
    }
}
