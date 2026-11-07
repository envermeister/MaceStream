import Foundation
import Network

final class LocalHLSStream: NSObject, URLSessionDataDelegate {
    enum StreamError: LocalizedError {
        case alreadyStarted
        case listenerFailed
        case invalidHTTPResponse
        case httpStatus(Int)
        case invalidTransportStream
        case segmentTooLarge
        case streamEnded
        case connection(String)

        var errorDescription: String? {
            switch self {
            case .alreadyStarted:
                return "The local stream has already been started."
            case .listenerFailed:
                return "Could not start the local playback server."
            case .invalidHTTPResponse:
                return "The engine returned an invalid playback response."
            case .httpStatus(let status):
                return "The engine returned HTTP error \(status) for the media stream."
            case .invalidTransportStream:
                return "The engine did not provide a valid MPEG transport stream."
            case .segmentTooLarge:
                return "The stream did not provide a usable video keyframe."
            case .streamEnded:
                return "The media stream ended unexpectedly."
            case .connection(let message):
                return message
            }
        }
    }

    var onFailure: ((Error) -> Void)?

    private let stateQueue = DispatchQueue(label: "com.macestream.local-hls")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let sessionConfiguration: URLSessionConfiguration
    private let retainedSegmentCount = 6
    private let initialSegmentCount = 3

    private var segmenter = TransportStreamSegmenter()
    private var segments: [TransportStreamSegment] = []
    private var maximumObservedDuration: Double = 4
    private var rawSession: URLSession?
    private var rawTask: URLSessionDataTask?
    private var listener: NWListener?
    private var listenerContinuation: CheckedContinuation<UInt16, Error>?
    private var readyContinuation: CheckedContinuation<URL, Error>?
    private var connections: [UUID: NWConnection] = [:]
    private var hasStarted = false
    private var isStopped = false

    init(configuration: URLSessionConfiguration? = nil) {
        if let configuration {
            sessionConfiguration = configuration
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 0
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.httpMaximumConnectionsPerHost = 1
            sessionConfiguration = configuration
        }
        super.init()
        stateQueue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        rawTask?.cancel()
        rawSession?.invalidateAndCancel()
        listener?.cancel()
        connections.values.forEach { $0.cancel() }
    }

    func start(rawURL: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            let port = try await startListener()
            try startRawStream(rawURL: rawURL)
            return try await waitUntilReady(port: port)
        } onCancel: {
            stop()
        }
    }

    func stop() {
        performSync {
            stopOnQueue(with: CancellationError())
        }
    }

    private func performSync(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            work()
        } else {
            stateQueue.sync(execute: work)
        }
    }

    private func startListener() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            stateQueue.async { [self] in
                guard !self.hasStarted, !self.isStopped else {
                    continuation.resume(throwing: StreamError.alreadyStarted)
                    return
                }
                self.hasStarted = true
                self.listenerContinuation = continuation

                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    listener.stateUpdateHandler = { [weak self] state in
                        self?.handleListenerState(state)
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        self?.serve(connection)
                    }
                    listener.start(queue: self.stateQueue)
                } catch {
                    self.listenerContinuation = nil
                    continuation.resume(throwing: StreamError.listenerFailed)
                }
            }
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener?.port?.rawValue, port > 0 else {
                failOnQueue(with: StreamError.listenerFailed)
                return
            }
            if let continuation = listenerContinuation {
                listenerContinuation = nil
                continuation.resume(returning: port)
            }
        case .failed:
            failOnQueue(with: StreamError.listenerFailed)
        case .cancelled:
            break
        default:
            break
        }
    }

    private func startRawStream(rawURL: URL) throws {
        try performSyncThrowing {
            guard !isStopped else { throw CancellationError() }
            let configuration = sessionConfiguration
            let delegateQueue = OperationQueue()
            delegateQueue.maxConcurrentOperationCount = 1
            delegateQueue.underlyingQueue = stateQueue
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
            rawSession = session
            var request = URLRequest(url: rawURL)
            request.setValue("video/mp2t, application/octet-stream;q=0.9, */*;q=0.1", forHTTPHeaderField: "Accept")
            let task = session.dataTask(with: request)
            rawTask = task
            task.resume()
        }
    }

    private func performSyncThrowing(_ work: () throws -> Void) throws {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            try work()
        } else {
            try stateQueue.sync(execute: work)
        }
    }

    private func waitUntilReady(port: UInt16) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            stateQueue.async {
                guard !self.isStopped else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if self.segments.count >= self.initialSegmentCount {
                    continuation.resume(returning: self.playlistURL(port: port))
                } else {
                    self.readyContinuation = continuation
                }
            }
        }
    }

    private func playlistURL(port: UInt16) -> URL {
        URL(string: "http://127.0.0.1:\(port)/playlist.m3u8")!
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard !isStopped else {
            completionHandler(.cancel)
            return
        }
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            failOnQueue(with: StreamError.invalidHTTPResponse)
            return
        }
        guard (200..<300).contains(response.statusCode) else {
            completionHandler(.cancel)
            failOnQueue(with: StreamError.httpStatus(response.statusCode))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !isStopped, !data.isEmpty else { return }
        do {
            let completedSegments = try segmenter.append(data)
            for segment in completedSegments {
                segments.append(segment)
                maximumObservedDuration = max(maximumObservedDuration, segment.duration)
            }
            if segments.count > retainedSegmentCount {
                segments.removeFirst(segments.count - retainedSegmentCount)
            }
            if segments.count >= initialSegmentCount,
               let port = listener?.port?.rawValue,
               let continuation = readyContinuation {
                readyContinuation = nil
                continuation.resume(returning: playlistURL(port: port))
            }
        } catch TransportStreamSegmenter.SegmenterError.invalidStream {
            failOnQueue(with: StreamError.invalidTransportStream)
        } catch TransportStreamSegmenter.SegmenterError.segmentTooLarge {
            failOnQueue(with: StreamError.segmentTooLarge)
        } catch {
            failOnQueue(with: StreamError.connection(error.localizedDescription))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !isStopped else { return }
        if let error {
            failOnQueue(with: StreamError.connection(error.localizedDescription))
        } else {
            failOnQueue(with: StreamError.streamEnded)
        }
    }

    private func failOnQueue(with error: Error) {
        guard !isStopped else { return }
        if let continuation = listenerContinuation {
            listenerContinuation = nil
            continuation.resume(throwing: error)
        }
        if let continuation = readyContinuation {
            readyContinuation = nil
            continuation.resume(throwing: error)
        }
        let failureHandler = onFailure
        stopOnQueue(with: error)
        if let failureHandler {
            DispatchQueue.main.async {
                failureHandler(error)
            }
        }
    }

    private func stopOnQueue(with error: Error) {
        guard !isStopped else { return }
        isStopped = true
        rawTask?.cancel()
        rawTask = nil
        rawSession?.invalidateAndCancel()
        rawSession = nil
        listener?.cancel()
        listener = nil
        let activeConnections = Array(connections.values)
        connections.removeAll()
        activeConnections.forEach { $0.cancel() }
        segments.removeAll()

        if let continuation = listenerContinuation {
            listenerContinuation = nil
            continuation.resume(throwing: error)
        }
        if let continuation = readyContinuation {
            readyContinuation = nil
            continuation.resume(throwing: error)
        }
    }

    private func serve(_ connection: NWConnection) {
        guard !isStopped else {
            connection.cancel()
            return
        }
        let identifier = UUID()
        connections[identifier] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self else { return }
            switch state {
            case .failed:
                if let connection {
                    self.connections.removeValue(forKey: identifier)
                    connection.cancel()
                }
            case .cancelled:
                self.connections.removeValue(forKey: identifier)
            default:
                break
            }
        }
        connection.start(queue: stateQueue)
        receiveRequest(on: connection, identifier: identifier, accumulated: Data())
    }

    private func receiveRequest(on connection: NWConnection, identifier: UUID, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
            [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection, !self.isStopped else { return }
            var request = accumulated
            if let data { request.append(data) }
            if error != nil {
                self.closeConnection(connection, identifier: identifier)
                return
            }
            if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.respond(to: request, on: connection, identifier: identifier)
            } else if isComplete || request.count >= 16 * 1024 {
                self.closeConnection(connection, identifier: identifier)
            } else {
                self.receiveRequest(on: connection, identifier: identifier, accumulated: request)
            }
        }
    }

    private func respond(to request: Data, on connection: NWConnection, identifier: UUID) {
        guard let text = String(data: request, encoding: .utf8),
              let firstLine = text.components(separatedBy: "\r\n").first else {
            closeConnection(connection, identifier: identifier)
            return
        }
        let fields = firstLine.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2 else {
            closeConnection(connection, identifier: identifier)
            return
        }
        let method = String(fields[0])
        let target = String(fields[1]).split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        let isHead = method == "HEAD"
        guard method == "GET" || isHead else {
            sendResponse(
                status: "405 Method Not Allowed",
                contentType: "text/plain; charset=utf-8",
                body: Data("Method not allowed".utf8),
                headOnly: isHead,
                on: connection,
                identifier: identifier
            )
            return
        }

        if target == "/playlist.m3u8" {
            sendResponse(
                status: "200 OK",
                contentType: "application/vnd.apple.mpegurl",
                body: Data(manifest().utf8),
                headOnly: isHead,
                on: connection,
                identifier: identifier
            )
            return
        }
        if target.hasPrefix("/segment"), target.hasSuffix(".ts"),
           let index = Int(target.dropFirst(8).dropLast(3)),
           let segment = segments.first(where: { $0.index == index }) {
            sendResponse(
                status: "200 OK",
                contentType: "video/mp2t",
                body: segment.data,
                headOnly: isHead,
                on: connection,
                identifier: identifier
            )
            return
        }
        sendResponse(
            status: "404 Not Found",
            contentType: "text/plain; charset=utf-8",
            body: Data("Not found".utf8),
            headOnly: isHead,
            on: connection,
            identifier: identifier
        )
    }

    private func manifest() -> String {
        let targetDuration = max(4, Int(maximumObservedDuration.rounded(.up)))
        let mediaSequence = segments.first?.index ?? 0
        var text = "#EXTM3U\n"
        text += "#EXT-X-VERSION:3\n"
        text += "#EXT-X-TARGETDURATION:\(targetDuration)\n"
        text += "#EXT-X-MEDIA-SEQUENCE:\(mediaSequence)\n"
        text += "#EXT-X-DISCONTINUITY-SEQUENCE:0\n"
        text += "#EXT-X-INDEPENDENT-SEGMENTS\n"
        for segment in segments {
            let duration = String(format: "%.3f", segment.duration)
            let name = String(format: "segment%06d.ts", segment.index)
            text += "#EXTINF:\(duration),\n"
            text += "\(name)\n"
        }
        return text
    }

    private func sendResponse(
        status: String,
        contentType: String,
        body: Data,
        headOnly: Bool,
        on connection: NWConnection,
        identifier: UUID
    ) {
        let headers = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Cache-Control: no-cache\r\n"
            + "Connection: close\r\n\r\n"
        let responseBody = headOnly ? Data() : body
        connection.send(content: Data(headers.utf8) + responseBody, completion: .contentProcessed {
            [weak self, weak connection] _ in
            guard let self, let connection else { return }
            self.closeConnection(connection, identifier: identifier)
        })
    }

    private func closeConnection(_ connection: NWConnection, identifier: UUID) {
        connections.removeValue(forKey: identifier)
        connection.cancel()
    }
}
