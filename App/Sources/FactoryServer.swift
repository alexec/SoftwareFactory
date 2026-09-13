import Foundation
import Network
import SoftwareFactoryKit

/// The factory's door: a TCP listener on one port, speaking the little HTTP in
/// SoftwareFactoryKit. MCP clients POST to /mcp; the phone uses /api. Advertised over Bonjour as
/// `_softwarefactory._tcp` so the phone finds it without an address.
final class FactoryServer: @unchecked Sendable {
    static let defaultPort: UInt16 = 4747
    static let serviceType = "_softwarefactory._tcp"

    let router: HTTPRouter
    let port: UInt16
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "factory.listener")
    private let onState: @Sendable (String) -> Void

    init(router: HTTPRouter, port: UInt16, onState: @escaping @Sendable (String) -> Void) {
        self.router = router
        self.port = port
        self.onState = onState
    }

    func start() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            listener.service = NWListener.Service(name: Host.current().localizedName ?? "Taktu: Software Factory", type: Self.serviceType)
            listener.stateUpdateHandler = { [onState, port] state in
                switch state {
                case .ready: onState("Listening on port \(port)")
                case .failed(let error): onState("Could not listen on port \(port): \(error.localizedDescription)")
                case .cancelled: onState("Stopped")
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            onState("Could not listen on port \(port): \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func serve(_ connection: NWConnection) {
        // Each connection gets its own queue because a request can block for minutes
        // (escalation_await) and must not hold up the others.
        connection.start(queue: DispatchQueue(label: "factory.connection"))
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            while let (request, consumed) = HTTPRequest.parse(buffer) {
                buffer.removeFirst(consumed)
                let response = self.router.respond(to: request)
                connection.send(content: response.serialized, completion: .contentProcessed { _ in })
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(connection, buffer: buffer)
        }
    }
}
