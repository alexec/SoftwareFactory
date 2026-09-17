#if os(macOS)
import Foundation

/// The wire between the app and the daemon: a unix socket carrying one JSON request and
/// one JSON reply per connection.
///
/// One request per connection, deliberately. There is no subscription and nothing is
/// streamed, because the stream is already a file: the daemon appends every line an
/// agent sends to `transcripts/<agent>.jsonl` and the app reads it the way it reads the
/// rest of the store. A socket that also carried the conversation would be a second copy
/// of the truth, and two copies of the truth disagree. What is left is small enough that
/// a connection per request costs nothing and leaks nothing. (T373.)
public enum AgentSocket {
    public static let backlog: Int32 = 16

    // MARK: Serving

    /// Listens until something goes wrong. Blocks, so the daemon calls it on its main
    /// thread and does nothing else.
    public static func serve(_ floor: AgentFloor, at path: String = AgentDaemon.socketPath) throws {
        // A socket file left by a daemon that crashed would make bind fail. Nothing else
        // is allowed to be there: the app checks with a ping before it starts one.
        unlink(path)
        let listening = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listening >= 0 else { throw Failure.cannotListen("socket: \(errno)") }
        guard var address = makeAddress(path) else {
            close(listening)
            throw Failure.cannotListen("the path is too long for a unix socket: \(path)")
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listening, $0, size) }
        }
        guard bound == 0 else {
            close(listening)
            throw Failure.cannotListen("bind: \(errno)")
        }
        // Nobody but this person. The file permissions are the whole access story, which
        // is the reason for a socket rather than a port.
        chmod(path, 0o600)
        guard listen(listening, backlog) == 0 else {
            close(listening)
            throw Failure.cannotListen("listen: \(errno)")
        }

        while true {
            let connection = accept(listening, nil, nil)
            guard connection >= 0 else {
                if errno == EINTR { continue }
                break
            }
            // One short-lived thread per request. A request is a dictionary lookup or a
            // process spawn; there are never more than a handful in flight.
            Thread.detachNewThread { answer(connection, with: floor) }
        }
        close(listening)
        unlink(path)
    }

    private static func answer(_ connection: Int32, with floor: AgentFloor) {
        defer { close(connection) }
        guard let line = readLine(from: connection),
              let request = AgentDaemon.decode(AgentDaemon.Request.self, from: line)
        else {
            write(connection, AgentDaemon.encode(AgentDaemon.Reply.no(AgentDaemon.Reply.notARequest)))
            return
        }
        // The floor's work is async and this thread is not. A semaphore rather than
        // making the accept loop async: the loop is three POSIX calls and turning it
        // inside out would buy nothing.
        let done = DispatchSemaphore(value: 0)
        let reply = Box<AgentDaemon.Reply>(AgentDaemon.Reply.no("The daemon did not answer."))
        Task {
            reply.value = await floor.handle(request)
            done.signal()
        }
        done.wait()
        write(connection, AgentDaemon.encode(reply.value))
    }

    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    // MARK: Asking

    /// One request, one reply. Never throws for the daemon simply not being there:
    /// that is an answer, and the app draws it as the floor being down.
    public static func ask(_ request: AgentDaemon.Request, at path: String = AgentDaemon.socketPath,
                           patience: TimeInterval = 180) -> AgentDaemon.Reply {
        let connection = socket(AF_UNIX, SOCK_STREAM, 0)
        guard connection >= 0 else { return .no("Could not open a socket.") }
        defer { close(connection) }
        var timeout = timeval(tv_sec: Int(patience), tv_usec: 0)
        setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        guard var address = makeAddress(path) else { return .no("The daemon's socket path is too long.") }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let joined = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(connection, $0, size) }
        }
        guard joined == 0 else { return .no(Self.floorIsDown) }
        write(connection, AgentDaemon.encode(request))
        // Half close, so the daemon's read ends without needing a length.
        shutdown(connection, SHUT_WR)
        guard let line = readLine(from: connection) else { return .no("The daemon did not answer.") }
        // It answered and the answer would not read. Said apart from silence on purpose:
        // the two look identical from here and want opposite things done about them, and
        // an app that says "no answer" about a daemon happily talking to five agents is
        // the wrong place to start looking.
        guard let reply = AgentDaemon.decode(AgentDaemon.Reply.self, from: line) else {
            return .no(Self.cannotRead)
        }
        return reply
    }

    /// What the app says when nothing is listening. Not an error: the daemon not running
    /// is the ordinary state on a Mac that has not started an agent yet.
    public static let floorIsDown = "The agent daemon is not running."

    /// The daemon is there and this build cannot read what it said. An older daemon left
    /// over from before a rebuild, which is the ordinary way this happens: it outlives the
    /// app on purpose. Restarting it ends the agents it is holding, so it says what is
    /// wrong rather than doing it.
    public static let cannotRead = "The agent daemon is running an older build than this app and answered with something it could not read. Restart the daemon when its agents can be spared."

    public static func isUp(at path: String = AgentDaemon.socketPath) -> Bool {
        ask(AgentDaemon.Request(op: .ping), at: path, patience: 2).ok
    }

    /// A unix address, or nil when the path will not fit in one. 104 characters is the
    /// cap, which is why the socket does not live under the store: a group container path
    /// spends most of that before we start.
    static func makeAddress(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { return nil }
        withUnsafeMutablePointer(to: &address.sun_path) { slot in
            path.withCString { source in
                _ = strncpy(UnsafeMutableRawPointer(slot).assumingMemoryBound(to: CChar.self),
                            source, capacity - 1)
            }
        }
        return address
    }

    // MARK: Bytes

    private static func readLine(from connection: Int32) -> Data? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let got = recv(connection, &chunk, chunk.count, 0)
            if got > 0 {
                buffer.append(contentsOf: chunk[0..<got])
                if let end = buffer.firstIndex(of: 0x0A) { return buffer[buffer.startIndex..<end] }
                // A request is one line. Anything enormous is not one of ours.
                if buffer.count > 4_000_000 { return nil }
                continue
            }
            if got == 0 { return buffer.isEmpty ? nil : buffer }
            if errno == EINTR { continue }
            return nil
        }
    }

    @discardableResult
    private static func write(_ connection: Int32, _ data: Data) -> Bool {
        var sent = 0
        return data.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return false }
            while sent < data.count {
                let wrote = send(connection, base.advanced(by: sent), data.count - sent, 0)
                if wrote > 0 { sent += wrote; continue }
                if wrote < 0, errno == EINTR { continue }
                return false
            }
            return true
        }
    }

    public enum Failure: LocalizedError {
        case cannotListen(String)
        public var errorDescription: String? {
            switch self {
            case .cannotListen(let why): "The daemon could not listen: \(why)"
            }
        }
    }
}
#endif
