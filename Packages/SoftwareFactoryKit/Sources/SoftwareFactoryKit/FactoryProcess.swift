import Foundation

/// The app's own process, written down where anything at a shell can find it.
///
/// An agent that has just built the Mac app has to stop the one that is running, and
/// `osascript -e 'tell application "Software Factory" to quit'` silently does nothing
/// from an agent's terminal. The terminal is not the reason it looks like the app is
/// ignoring Quit: the agent's shell belongs to a Background launchd session (tmux was
/// started outside the Aqua session), and in a Background session LaunchServices cannot
/// see a GUI app as running. AppleScript then answers `is running` with false and quietly
/// declines to send the event at all, because it will not launch an app just to quit it.
/// `get name` still answers, off the bundle rather than the process, so the app looks
/// alive and deaf. It is neither: an event addressed to the process quits it at once.
///
/// So the factory writes down which process it is, the same pid and start time pairing
/// every agent uses, and `software-factory quit` addresses the event to that process.
/// (T271, 15 Sep 2026.)
public struct FactoryProcess: Codable, Sendable, Equatable {
    public var version = Records.version
    public var pid: Int32
    /// When that process started, read from the kernel. A pid on its own is recycled.
    public var startedAt: Date
    /// When the app last wrote this down, for a reader wondering how old it is.
    public var wrote: Date

    public init(pid: Int32, startedAt: Date, wrote: Date = .now) {
        self.pid = pid
        self.startedAt = startedAt
        self.wrote = wrote
    }

    /// The process this names, if it is still the one that was written down.
    public var isRunning: Bool { ProcessCheck.isRunning(pid: pid, startedAt: startedAt) }

    /// This process, ready to write down. Nil when the kernel will not say when it
    /// started, because half the pair is worth nothing.
    public static func current(now: Date = .now) -> FactoryProcess? {
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let started = ProcessCheck.startTime(of: pid) else { return nil }
        return FactoryProcess(pid: pid, startedAt: started, wrote: now)
    }
}
