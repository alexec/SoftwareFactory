import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The agent numbers this factory has given out, kept on disk rather than worked out
/// from the agents still in the store. A6 means one agent for the life of the factory:
/// delete its record, and A6 is still spent.
///
/// Taking a number is creating its file, and only one creator can win, so the app and
/// the server can both hand out numbers without talking to each other. (Alex, 13 Sep
/// 2026: keep a long-term atomic counter, persisted to disk.)
public struct AgentNumbers: Sendable {
    public static let folder = "agent-numbers"

    let root: URL

    public init(root: URL) throws {
        self.root = root.appending(path: Self.folder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    /// The highest number spent, whether its agent is still here or not. Zero when none
    /// has been given out.
    public var highest: Int {
        let taken = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return taken.compactMap(Int.init).max() ?? 0
    }

    /// The next free number, taken and written down before it is handed over, so two
    /// registrations at once can never come away with the same one. `notBelow` seeds a
    /// store written before this folder existed: pass the highest number its agents
    /// already carry.
    public func take(notBelow floor: Int = 0) -> Int {
        var candidate = max(floor, highest) + 1
        while !claim(candidate) { candidate += 1 }
        return candidate
    }

    /// Takes one particular number, for an agent that asks for it by name. Answers false
    /// when it is already spent: numbers are never given out twice.
    @discardableResult
    public func claim(_ number: Int) -> Bool {
        guard number > 0 else { return false }
        let path = root.appending(path: String(number)).path
        // O_EXCL is the whole trick: the file is created by exactly one caller, and
        // everyone else is told it is there already.
        let fd = open(path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    /// Whether a number has been given out. A number nobody has taken is free.
    public func isSpent(_ number: Int) -> Bool {
        FileManager.default.fileExists(atPath: root.appending(path: String(number)).path)
    }
}
