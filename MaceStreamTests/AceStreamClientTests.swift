import XCTest
@testable import MaceStream

final class AceStreamClientTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        MockURLProtocol.responder = nil
        super.tearDown()
    }

    func testVersionResponse() async throws {
        MockURLProtocol.responder = { request in
            try self.respond(request, json: "{\"result\":{\"version\":\"3.2.11\"}}")
        }
        let version = try await AceStreamClient(session: session).getVersion(
            endpoint: EngineEndpoint(host: "127.0.0.1", port: 12345)
        )
        XCTAssertEqual(version, "3.2.11")
    }

    func testPlaybackURLsAreMovedToDynamicLoopbackPort() async throws {
        MockURLProtocol.responder = { request in
            let json = """
            {"response":{"playback_url":"http://192.168.64.2:6878/ace/r/stream","stat_url":"/ace/stat?pid=abc","command_url":"http://127.0.0.1:6878/ace/cmd?pid=abc"},"error":null}
            """
            return try self.respond(request, json: json)
        }
        let stream = try await AceStreamClient(session: session).startStream(
            contentID: "0123456789abcdef0123456789abcdef01234567",
            endpoint: EngineEndpoint(host: "127.0.0.1", port: 23456)
        )
        XCTAssertEqual(stream.playbackURL.host(), "127.0.0.1")
        XCTAssertEqual(stream.playbackURL.port, 23456)
        XCTAssertEqual(stream.playbackURL.path, "/ace/r/stream")
        XCTAssertEqual(stream.statisticsURL?.host(), "127.0.0.1")
        XCTAssertEqual(stream.statisticsURL?.port, 23456)
        XCTAssertEqual(stream.commandURL?.port, 23456)
    }

    func testStatisticsResponse() async throws {
        MockURLProtocol.responder = { request in
            let json = """
            {"response":{"status":"prebuf","total_progress":72.5,"speed_down":1536,"speed_up":12,"peers":9,"downloaded":1024}}
            """
            return try self.respond(request, json: json)
        }
        let stats = try await AceStreamClient(session: session).fetchStatistics(
            url: URL(string: "http://127.0.0.1:12345/stat")!
        )
        XCTAssertEqual(stats.progress, 72.5)
        XCTAssertEqual(stats.peers, 9)
        XCTAssertEqual(stats.downloadSpeed, 1536)
        XCTAssertEqual(stats.downloadedBytes, 1024)
        XCTAssertTrue(stats.isPrebuffering)
    }

    private func respond(_ request: URLRequest, json: String) throws -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(json.utf8))
    }
}

private final class MockURLProtocol: URLProtocol {
    static var responder: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let responder = Self.responder else {
                throw URLError(.unknown)
            }
            let (response, data) = try responder(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
