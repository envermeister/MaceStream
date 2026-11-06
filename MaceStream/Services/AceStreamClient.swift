import Foundation

struct AceStreamClient: Sendable {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 30
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.httpMaximumConnectionsPerHost = 8
            self.session = URLSession(configuration: configuration)
        }
    }

    func getVersion(endpoint: EngineEndpoint) async throws -> String {
        let url = endpoint.url(
            path: "/webui/api/service",
            queryItems: [URLQueryItem(name: "method", value: "get_version")]
        )
        let data = try await getJSON(url, timeout: 3)
        let response = nestedResponse(in: data)
        guard let version = response["version"] ?? data["version"],
              !String(describing: version).isEmpty else {
            throw AceStreamClientError.invalidResponse("Could not parse the engine version response.")
        }
        return String(describing: version)
    }

    func startStream(contentID: String, endpoint: EngineEndpoint) async throws -> StreamSession {
        let processID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let url = endpoint.url(
            path: "/ace/getstream",
            queryItems: [
                URLQueryItem(name: "id", value: contentID),
                URLQueryItem(name: "format", value: "json"),
                URLQueryItem(name: "pid", value: processID)
            ]
        )

        do {
            let data = try await getJSON(url, timeout: 20)
            if let error = data["error"], !String(describing: error).isEmpty {
                throw AceStreamClientError.engine(String(describing: error))
            }
            return try session(
                from: data,
                contentID: contentID,
                processID: processID,
                endpoint: endpoint,
                fallback: false
            )
        } catch {
            try Task.checkCancellation()
            if Task.isCancelled { throw CancellationError() }
            return try await manifestFallback(
                contentID: contentID,
                processID: processID,
                endpoint: endpoint
            )
        }
    }

    func fetchStatistics(url: URL) async throws -> PlaybackStats {
        let data = try await getJSON(url, timeout: 3)
        let response = nestedResponse(in: data)

        func number(_ key: String) -> Double {
            if let value = response[key] as? NSNumber { return value.doubleValue }
            return Double(String(describing: response[key] ?? "")) ?? 0
        }

        func byteCount(_ key: String) -> UInt64 {
            UInt64(max(0, number(key)).rounded(.down))
        }

        let totalProgress = number("total_progress")
        return PlaybackStats(
            status: String(describing: response["status"] ?? ""),
            progress: min(max(totalProgress > 0 ? totalProgress : number("progress"), 0), 100),
            downloadSpeed: max(0, number("speed_down")),
            uploadSpeed: max(0, number("speed_up")),
            peers: min(max(Int(number("peers").rounded()), 0), 1_000_000),
            downloadedBytes: byteCount("downloaded"),
            uploadedBytes: byteCount("uploaded")
        )
    }

    func stopStream(_ session: StreamSession) async {
        guard let commandURL = session.commandURL,
              var components = URLComponents(url: commandURL, resolvingAgainstBaseURL: false) else {
            return
        }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "method" }
        queryItems.append(URLQueryItem(name: "method", value: "stop"))
        components.queryItems = queryItems
        guard let url = components.url else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        _ = try? await self.session.data(for: request)
    }

    private func manifestFallback(
        contentID: String,
        processID: String,
        endpoint: EngineEndpoint
    ) async throws -> StreamSession {
        let manifestURL = endpoint.url(
            path: "/ace/manifest.m3u8",
            queryItems: [
                URLQueryItem(name: "id", value: contentID),
                URLQueryItem(name: "format", value: "json"),
                URLQueryItem(name: "pid", value: processID)
            ]
        )

        if let data = try? await getJSON(manifestURL, timeout: 20),
           let session = try? session(
               from: data,
               contentID: contentID,
               processID: processID,
               endpoint: endpoint,
               fallback: true
           ) {
            return session
        }

        try Task.checkCancellation()
        var components = URLComponents(url: manifestURL, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []).filter { $0.name != "format" }
        return StreamSession(
            contentID: contentID,
            processID: processID,
            playbackURL: components.url!,
            statisticsURL: nil,
            commandURL: nil,
            usesManifestFallback: true
        )
    }

    private func session(
        from data: [String: Any],
        contentID: String,
        processID: String,
        endpoint: EngineEndpoint,
        fallback: Bool
    ) throws -> StreamSession {
        let response = nestedResponse(in: data)
        guard let rawPlaybackURL = response["playback_url"] as? String,
              !rawPlaybackURL.isEmpty else {
            throw AceStreamClientError.invalidResponse("The engine did not return a playback URL.")
        }
        return StreamSession(
            contentID: contentID,
            processID: processID,
            playbackURL: try resolve(rawPlaybackURL, endpoint: endpoint),
            statisticsURL: try optionalURL(response["stat_url"], endpoint: endpoint),
            commandURL: try optionalURL(response["command_url"], endpoint: endpoint),
            usesManifestFallback: fallback
        )
    }

    private func nestedResponse(in data: [String: Any]) -> [String: Any] {
        if let response = data["response"] as? [String: Any] { return response }
        if let result = data["result"] as? [String: Any] { return result }
        return data
    }

    private func optionalURL(_ value: Any?, endpoint: EngineEndpoint) throws -> URL? {
        guard let rawValue = value as? String, !rawValue.isEmpty else { return nil }
        return try resolve(rawValue, endpoint: endpoint)
    }

    private func resolve(_ rawValue: String, endpoint: EngineEndpoint) throws -> URL {
        guard let parsed = URL(string: rawValue, relativeTo: endpoint.baseURL)?.absoluteURL,
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw AceStreamClientError.invalidResponse("The engine returned an invalid URL.")
        }

        let localHosts: Set<String> = [
            "", "127.0.0.1", "localhost", "::1", "0.0.0.0", "192.168.64.2", "192.168.64.23"
        ]
        guard localHosts.contains(parsed.host ?? "") else { return parsed }
        guard var components = URLComponents(url: parsed, resolvingAgainstBaseURL: false) else {
            throw AceStreamClientError.invalidResponse("Could not resolve the engine URL.")
        }
        components.scheme = "http"
        components.host = endpoint.host
        components.port = Int(endpoint.port)
        guard let url = components.url else {
            throw AceStreamClientError.invalidResponse("Could not create the local playback URL.")
        }
        return url
    }

    private func getJSON(_ url: URL, timeout: TimeInterval) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
            switch error.code {
            case .timedOut:
                throw AceStreamClientError.connection("The engine request timed out.")
            case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet:
                throw AceStreamClientError.connection("Could not connect to the AceStream engine.")
            default:
                throw AceStreamClientError.connection(error.localizedDescription)
            }
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AceStreamClientError.invalidResponse("The engine returned an invalid HTTP response.")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AceStreamClientError.connection("The engine returned HTTP error \(httpResponse.statusCode).")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw AceStreamClientError.invalidResponse("The engine did not return a JSON object.")
        }
        return dictionary
    }
}

enum AceStreamClientError: LocalizedError {
    case connection(String)
    case invalidResponse(String)
    case engine(String)

    var errorDescription: String? {
        switch self {
        case .connection(let message), .invalidResponse(let message), .engine(let message):
            return message
        }
    }
}
