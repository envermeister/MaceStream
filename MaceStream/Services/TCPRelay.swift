import Foundation
import Network

/// A loopback-only, bidirectional TCP bridge to vfkit's Unix/virtio-vsock endpoint.
/// Each listener owns an ephemeral port, so MaceStream never has to take over port 6878.
final class TCPRelay: @unchecked Sendable {
    private struct Bridge {
        let client: NWConnection
        let upstream: NWConnection
    }

    private enum Direction: Hashable {
        case clientToUpstream
        case upstreamToClient
    }

    private let listener: NWListener
    private let upstreamSocketPath: String
    private let queue = DispatchQueue(label: "app.macestream.tcp-relay", qos: .userInitiated)
    private let lock = NSLock()
    private var bridges: [UUID: Bridge] = [:]
    private var completedDirections: [UUID: Set<Direction>] = [:]
    private var isStopped = false

    private init(upstreamSocketPath: String) throws {
        self.upstreamSocketPath = upstreamSocketPath
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: .any
        )
        listener = try NWListener(using: parameters)
    }

    static func start(upstreamSocketPath: String) async throws -> (relay: TCPRelay, port: UInt16) {
        let relay = try TCPRelay(upstreamSocketPath: upstreamSocketPath)
        let port = try await relay.startListener()
        return (relay, port)
    }

    func stop() {
        lock.lock()
        if isStopped {
            lock.unlock()
            return
        }
        isStopped = true
        let activeBridges = bridges
        bridges.removeAll()
        completedDirections.removeAll()
        lock.unlock()

        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
        for bridge in activeBridges.values {
            bridge.client.stateUpdateHandler = nil
            bridge.upstream.stateUpdateHandler = nil
            bridge.client.cancel()
            bridge.upstream.cancel()
        }
    }

    private func startListener() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            let start = ListenerStart(continuation: continuation)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = self.listener.port?.rawValue else {
                        start.fail(with: TCPRelayError.listenerUnavailable)
                        return
                    }
                    start.succeed(with: port)
                case .failed(let error):
                    start.fail(with: error)
                case .cancelled:
                    start.fail(with: CancellationError())
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    private func accept(_ client: NWConnection) {
        let id = UUID()
        let upstream = NWConnection(
            to: NWEndpoint.unix(path: upstreamSocketPath),
            using: .tcp
        )

        // Setup and shutdown share this lock. Once stop() wins, no connection is started.
        lock.lock()
        guard !isStopped else {
            lock.unlock()
            client.cancel()
            upstream.cancel()
            return
        }
        bridges[id] = Bridge(client: client, upstream: upstream)
        completedDirections[id] = []
        client.stateUpdateHandler = { [weak self] state in
            if state.isTerminal { self?.closeBridge(id: id) }
        }
        upstream.stateUpdateHandler = { [weak self] state in
            if state.isTerminal { self?.closeBridge(id: id) }
        }
        client.start(queue: queue)
        upstream.start(queue: queue)
        lock.unlock()

        pump(from: client, to: upstream, id: id, direction: .clientToUpstream)
        pump(from: upstream, to: client, id: id, direction: .upstreamToClient)
    }

    private func pump(
        from source: NWConnection,
        to destination: NWConnection,
        id: UUID,
        direction: Direction
    ) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self, error == nil else {
                self?.closeBridge(id: id)
                return
            }

            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { [weak self] sendError in
                    guard let self, sendError == nil else {
                        self?.closeBridge(id: id)
                        return
                    }
                    if isComplete {
                        self.complete(direction, on: destination, id: id)
                    } else {
                        self.pump(from: source, to: destination, id: id, direction: direction)
                    }
                })
            } else if isComplete {
                complete(direction, on: destination, id: id)
            } else {
                pump(from: source, to: destination, id: id, direction: direction)
            }
        }
    }

    private func complete(_ direction: Direction, on destination: NWConnection, id: UUID) {
        lock.lock()
        guard !isStopped, completedDirections[id]?.contains(direction) == false else {
            lock.unlock()
            return
        }
        completedDirections[id]?.insert(direction)
        let bothDirectionsCompleted = completedDirections[id]?.count == 2
        lock.unlock()

        // Preserve the other direction: HTTP peers may close their write side before reading.
        destination.send(
            content: nil,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { [weak self] error in
                if error != nil || bothDirectionsCompleted {
                    self?.closeBridge(id: id)
                }
            }
        )
    }

    private func closeBridge(id: UUID) {
        lock.lock()
        let bridge = bridges.removeValue(forKey: id)
        completedDirections.removeValue(forKey: id)
        lock.unlock()
        guard let bridge else { return }
        bridge.client.stateUpdateHandler = nil
        bridge.upstream.stateUpdateHandler = nil
        bridge.client.cancel()
        bridge.upstream.cancel()
    }
}

private extension NWConnection.State {
    var isTerminal: Bool {
        switch self {
        case .failed, .cancelled: return true
        default: return false
        }
    }
}

private enum TCPRelayError: Error {
    case listenerUnavailable
}

/// Protects the exactly-once continuation without blocking the Network queue.
private final class ListenerStart: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, Error>?

    init(continuation: CheckedContinuation<UInt16, Error>) {
        self.continuation = continuation
    }

    func succeed(with port: UInt16) {
        takeContinuation()?.resume(returning: port)
    }

    func fail(with error: Error) {
        takeContinuation()?.resume(throwing: error)
    }

    private func takeContinuation() -> CheckedContinuation<UInt16, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let current = continuation
        continuation = nil
        return current
    }
}
