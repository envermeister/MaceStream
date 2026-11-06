import Foundation

struct EngineEndpoint: Equatable, Sendable {
    let host: String
    let port: UInt16

    var baseURL: URL {
        URL(string: "http://\(host):\(port)")!
    }

    func url(path: String, queryItems: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = path
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url!
    }
}

struct StreamSession: Equatable, Sendable {
    let contentID: String
    let processID: String
    let playbackURL: URL
    let statisticsURL: URL?
    let commandURL: URL?
    let usesManifestFallback: Bool
}
