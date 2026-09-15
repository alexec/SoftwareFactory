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

    /// Asks a process to quit the way its own Quit menu item would, and answers whether
    /// the event went out. macOS only, and only for a process on this machine.
    ///
    /// The event is addressed to the process, not to the application, and that is the
    /// whole point. `tell application "Software Factory" to quit` asks LaunchServices
    /// which running app carries that name, and from a shell in a Background launchd
    /// session, which is what an agent's terminal is, LaunchServices can see no GUI app
    /// running at all. AppleScript reads that as "not running", declines to launch an app
    /// just to quit it, and sends nothing, with no error to notice. Addressed to the pid
    /// there is nobody to ask and nothing to be wrong about. (T271.)
    ///
    /// This is the polite ending: the app runs its own termination, writes what it has
    /// and closes its port. `stop` is the other kind, for a process that will not go.
    @discardableResult
    public static func quit(pid: Int32?, startedAt: Date?) -> Bool {
        #if os(macOS)
        guard let pid, isRunning(pid: pid, startedAt: startedAt) else { return false }
        var target = pid
        guard let address = NSAppleEventDescriptor(
            descriptorType: typeKernelProcessID, bytes: &target, length: MemoryLayout<pid_t>.size)
        else { return false }
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEQuitApplication),
            targetDescriptor: address, returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        // No reply is waited for: an app that is quitting has better things to do than
        // answer, and whether it went is answered by asking the kernel afterwards.
        do {
            try event.sendEvent(options: .noReply, timeout: 2)
            return true
        } catch {
            return false
        }
        #else
        return false
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
