import Foundation
import Network
import SoftwareFactoryKit

/// Talks to the factory over the Bonjour endpoint itself, one connection per request,
/// speaking the package's HTTP. Network handles the address, the interface and IPv4 or
/// IPv6, which is what a URL to a link-local address gets wrong.
struct FactoryClient: Sendable {
    let endpoint: NWEndpoint
    let hostName: String

    enum ClientError: Error, LocalizedError {
        case failed(String)
        case closed

        var errorDescription: String? {
            switch self {
            case .failed(let why): why
            case .closed: "The factory closed the connection before answering."
            }
        }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let connection = NWConnection(to: endpoint, using: .tcp)
        let bytes = request.serialized(host: hostName)
        return try await withCheckedThrowingContinuation { continuation in
            let box = Box(continuation: continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: bytes, completion: .contentProcessed { error in
                        if let error { box.finish(.failure(ClientError.failed(error.localizedDescription))); connection.cancel() }
                    })
                    Self.receive(connection, buffer: Data(), box: box)
                case .failed(let error):
                    box.finish(.failure(ClientError.failed(error.localizedDescription)))
                    connection.cancel()
                case .waiting(let error):
                    box.finish(.failure(ClientError.failed(error.localizedDescription)))
                    connection.cancel()
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    private static func receive(_ connection: NWConnection, buffer: Data, box: Box) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let (response, _) = HTTPResponse.parse(buffer) {
                box.finish(.success(response))
                connection.cancel()
                return
            }
            if let error {
                box.finish(.failure(ClientError.failed(error.localizedDescription)))
                connection.cancel()
                return
            }
            if isComplete {
                box.finish(.failure(ClientError.closed))
                connection.cancel()
                return
            }
            receive(connection, buffer: buffer, box: box)
        }
    }

    /// A continuation may only be resumed once; the connection can report more than one thing.
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<HTTPResponse, Error>?

        init(continuation: CheckedContinuation<HTTPResponse, Error>) {
            self.continuation = continuation
        }

        func finish(_ result: Result<HTTPResponse, Error>) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(with: result)
        }
    }
}
