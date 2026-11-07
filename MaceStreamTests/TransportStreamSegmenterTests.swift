import XCTest
@testable import MaceStream

final class TransportStreamSegmenterTests: XCTestCase {
    func testFindsSyncAfterVariablePrefixAndSplitInput() throws {
        let packets = makePackets(keyframePTS: [0, 90_000, 180_000])
        let input = Data(repeating: 0x55, count: 83) + packets
        var segmenter = TransportStreamSegmenter()
        var segments: [TransportStreamSegment] = []
        let chunkSizes = [1, 17, 188, 3, 4096]

        var offset = 0
        var chunkIndex = 0
        while offset < input.count {
            let length = min(chunkSizes[chunkIndex % chunkSizes.count], input.count - offset)
            segments.append(contentsOf: try segmenter.append(input.subdata(in: offset..<(offset + length))))
            offset += length
            chunkIndex += 1
        }

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(try XCTUnwrap(segments.first).duration, 2, accuracy: 0.0001)
    }

    func testSegmentStartsWithPATPMTAndIDRKeyframe() throws {
        let pat = makePAT()
        let pmt = makePMT()
        let input = makePackets(keyframePTS: [0, 180_000, 270_000])
        var segmenter = TransportStreamSegmenter()

        let segments = try segmenter.append(input)

        XCTAssertEqual(segments.count, 1)
        let bytes = [UInt8](segments[0].data)
        XCTAssertEqual(Array(bytes.prefix(188)), [UInt8](pat))
        XCTAssertEqual(Array(bytes[188..<376]), [UInt8](pmt))
        XCTAssertEqual(bytes[376], 0x47)
        XCTAssertTrue(bytes[377] & 0x40 != 0)
        XCTAssertTrue(bytes.contains(0x65))
    }

    func testSPSAndPPSMarkNonIDRIntraFrameAsRandomAccess() throws {
        var segmenter = TransportStreamSegmenter()
        var input = makePAT() + makePMT()
        input.append(makeVideoPacket(pts: 0, isKeyframe: false, includesParameterSets: true))
        input.append(makeVideoPacket(pts: 90_000, isKeyframe: false))
        input.append(makeVideoPacket(pts: 180_000, isKeyframe: false, includesParameterSets: true))

        let segments = try segmenter.append(input)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].duration, 2, accuracy: 0.0001)
    }

    func testNormalizesPrivateAC3AndRemovesConditionalAccessDescriptors() throws {
        var segmenter = TransportStreamSegmenter()
        var input = makePAT() + makeDVBPMT()
        input.append(makeVideoPacket(pts: 0, isKeyframe: true))
        input.append(makeAudioPacket())
        input.append(makeVideoPacket(pts: 180_000, isKeyframe: true))

        let segments = try segmenter.append(input)

        XCTAssertEqual(segments.count, 1)
        let bytes = [UInt8](segments[0].data)
        XCTAssertEqual(bytes[193], 0x02)
        XCTAssertEqual(bytes[203], 0xf0)
        XCTAssertEqual(bytes[204], 0x00)
        XCTAssertEqual(bytes[205], 0x1b)
        XCTAssertEqual(bytes[210], 0x81)
        XCTAssertEqual(bytes[214], 0x06)
    }

    func testDropsMediaBeforeFirstKeyframe() throws {
        var segmenter = TransportStreamSegmenter()
        var input = makePAT() + makePMT()
        input.append(makeVideoPacket(pts: 0, isKeyframe: false))
        input.append(makeVideoPacket(pts: 90_000, isKeyframe: false))

        XCTAssertTrue(try segmenter.append(input).isEmpty)
        XCTAssertTrue(try segmenter.append(makeVideoPacket(pts: 180_000, isKeyframe: true)).isEmpty)
        let segments = try segmenter.append(makeVideoPacket(pts: 360_000, isKeyframe: true))
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].duration, 2, accuracy: 0.0001)
    }

    func testHandlesPTSWraparound() throws {
        let modulus: UInt64 = 1 << 33
        let input = makePackets(keyframePTS: [modulus - 90_000, 0, 90_000])
        var segmenter = TransportStreamSegmenter()

        let segments = try segmenter.append(input)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].duration, 2, accuracy: 0.0001)
    }

    func testRejectsDataWithoutTransportStreamSync() {
        var segmenter = TransportStreamSegmenter()
        XCTAssertThrowsError(try segmenter.append(Data(repeating: 0x55, count: 1_200))) { error in
            XCTAssertEqual(error as? TransportStreamSegmenter.SegmenterError, .invalidStream)
        }
    }

    func testRejectsUnboundedSegmentWithoutKeyframes() throws {
        var segmenter = TransportStreamSegmenter(maximumSegmentBytes: 188 * 16)
        var input = makePAT() + makePMT() + makeVideoPacket(pts: 0, isKeyframe: true)
        for index in 1...20 {
            input.append(makeVideoPacket(pts: UInt64(index * 9_000), isKeyframe: false))
        }

        XCTAssertThrowsError(try segmenter.append(input)) { error in
            XCTAssertEqual(error as? TransportStreamSegmenter.SegmenterError, .segmentTooLarge)
        }
    }

    func testLocalHLSFollowsRedirectAndServesPlaylistAndSegments() async throws {
        RawStreamMock.reset()
        RawStreamMock.payload = makePackets(keyframePTS: [0, 180_000, 360_000, 540_000])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RawStreamMock.self]
        let stream = LocalHLSStream(configuration: configuration)
        var reportedFailure: Error?
        stream.onFailure = { reportedFailure = $0 }
        defer {
            stream.stop()
            RawStreamMock.reset()
        }

        let playlistURL = try await stream.start(rawURL: URL(string: "http://engine.test/ace/r/session")!)
        let (playlistData, playlistResponse) = try await URLSession.shared.data(from: playlistURL)
        let playlist = try XCTUnwrap(String(data: playlistData, encoding: .utf8))
        XCTAssertEqual((playlistResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((playlistResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), "application/vnd.apple.mpegurl")
        XCTAssertTrue(playlist.contains("#EXT-X-MEDIA-SEQUENCE:0"))
        XCTAssertTrue(playlist.contains("#EXT-X-INDEPENDENT-SEGMENTS"))
        XCTAssertEqual(playlist.components(separatedBy: "#EXTINF:").count - 1, 3)
        XCTAssertEqual(RawStreamMock.requestPaths, ["/ace/r/session", "/content/session"])

        let segmentURL = playlistURL.deletingLastPathComponent().appendingPathComponent("segment000000.ts")
        let (segmentData, segmentResponse) = try await URLSession.shared.data(from: segmentURL)
        XCTAssertEqual((segmentResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((segmentResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), "video/mp2t")
        XCTAssertGreaterThan(segmentData.count, 3 * 188)
        XCTAssertEqual(segmentData.first, 0x47)

        stream.stop()
        XCTAssertNil(reportedFailure)
    }

    func testLocalHLSPropagatesEngineHTTPFailure() async {
        RawStreamMock.reset()
        RawStreamMock.mode = .httpError(500)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RawStreamMock.self]
        let stream = LocalHLSStream(configuration: configuration)
        defer {
            stream.stop()
            RawStreamMock.reset()
        }

        do {
            _ = try await stream.start(rawURL: URL(string: "http://engine.test/content/session")!)
            XCTFail("Expected the engine error to fail playback preparation")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("500"))
        }
    }

    func testStopBeforeFirstSegmentCancelsPreparation() async throws {
        RawStreamMock.reset()
        RawStreamMock.mode = .hold
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RawStreamMock.self]
        let stream = LocalHLSStream(configuration: configuration)
        defer { RawStreamMock.reset() }

        let preparation = Task {
            try await stream.start(rawURL: URL(string: "http://engine.test/content/session")!)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        stream.stop()
        do {
            _ = try await preparation.value
            XCTFail("Expected stop to cancel playback preparation")
        } catch {
            // Expected: stopping the stream must finish the pending start operation.
        }
    }

    private func makePackets(keyframePTS: [UInt64]) -> Data {
        var data = makePAT() + makePMT()
        for (index, pts) in keyframePTS.enumerated() {
            data.append(makeVideoPacket(pts: pts, isKeyframe: true))
            data.append(makeVideoPacket(pts: pts + 45_000, isKeyframe: false))
            if index < keyframePTS.count - 1 {
                data.append(makeAudioPacket())
            }
        }
        return data
    }

    private func makePAT() -> Data {
        makePacket(
            pid: 0,
            payloadUnitStart: true,
            payload: [
                0,
                0x00, 0xb0, 0x0d, 0x00, 0x01, 0xc1, 0x00, 0x00,
                0x00, 0x01, 0xf0, 0x00,
                0, 0, 0, 0
            ]
        )
    }

    private func makePMT() -> Data {
        makePacket(
            pid: 0x1000,
            payloadUnitStart: true,
            payload: [
                0,
                0x02, 0xb0, 0x12, 0x00, 0x01, 0xc1, 0x00, 0x00,
                0xe1, 0x00, 0xf0, 0x00,
                0x1b, 0xe1, 0x00, 0xf0, 0x00,
                0, 0, 0, 0
            ]
        )
    }

    private func makeDVBPMT() -> Data {
        var table: [UInt8] = [
            0x02, 0xb0, 0x00, 0x00, 0x84, 0xc1, 0x00, 0x00,
            0xe1, 0x00, 0xf0, 0x06,
            0x09, 0x04, 0x09, 0xf0, 0xff, 0x56,
            0x1b, 0xe1, 0x00, 0xf0, 0x00,
            0x06, 0xe1, 0x01, 0xf0, 0x08,
            0x6a, 0x00, 0x0a, 0x04, 0x64, 0x65, 0x75, 0x01
        ]
        let sectionLength = table.count - 3 + 4
        table[1] = table[1] & 0xf0 | UInt8((sectionLength >> 8) & 0x0f)
        table[2] = UInt8(sectionLength & 0xff)
        table.append(contentsOf: [0, 0, 0, 0])
        return makePacket(pid: 0x1000, payloadUnitStart: true, payload: [0] + table)
    }

    private func makeVideoPacket(pts: UInt64, isKeyframe: Bool, includesParameterSets: Bool = false) -> Data {
        let timestamp = pts & ((1 << 33) - 1)
        let encodedPTS: [UInt8] = [
            UInt8(0x20 | ((timestamp >> 30) & 0x07) << 1 | 1),
            UInt8((timestamp >> 22) & 0xff),
            UInt8(((timestamp >> 15) & 0x7f) << 1 | 1),
            UInt8((timestamp >> 7) & 0xff),
            UInt8((timestamp & 0x7f) << 1 | 1)
        ]
        let parameterSets: [UInt8] = includesParameterSets
            ? [0, 0, 0, 1, 0x67, 0, 0, 0, 1, 0x68]
            : []
        let payload: [UInt8] = [
            0, 0, 1, 0xe0, 0, 0, 0x80, 0x80, 0x05
        ] + encodedPTS + parameterSets + [0, 0, 0, 1, isKeyframe ? 0x65 : 0x41]
        return makePacket(pid: 0x100, payloadUnitStart: true, payload: payload)
    }

    private func makeAudioPacket() -> Data {
        makePacket(pid: 0x101, payloadUnitStart: false, payload: [0x55, 0x56, 0x57])
    }

    private func makePacket(pid: Int, payloadUnitStart: Bool, payload: [UInt8]) -> Data {
        var packet = [UInt8](repeating: 0xff, count: 188)
        packet[0] = 0x47
        packet[1] = UInt8((pid >> 8) & 0x1f) | (payloadUnitStart ? 0x40 : 0)
        packet[2] = UInt8(pid & 0xff)
        packet[3] = 0x10
        packet.replaceSubrange(4..<(4 + payload.count), with: payload)
        return Data(packet)
    }
}

private final class RawStreamMock: URLProtocol {
    enum Mode {
        case redirectAndStream
        case httpError(Int)
        case hold
    }

    static var mode: Mode = .redirectAndStream
    static var payload = Data()
    static var requestPaths: [String] = []
    static var didStop = false

    static func reset() {
        mode = .redirectAndStream
        payload = Data()
        requestPaths = []
        didStop = false
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.requestPaths.append(url.path)
        switch Self.mode {
        case .redirectAndStream:
            if url.path.hasPrefix("/ace/r/") {
                let location = URL(string: "http://engine.test/content/session")!
                let redirect = URLRequest(url: location)
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 302,
                    httpVersion: nil,
                    headerFields: ["Location": location.absoluteString]
                )!
                client?.urlProtocol(self, wasRedirectedTo: redirect, redirectResponse: response)
                return
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "video/mp2t"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.payload)
        case .httpError(let status):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .hold:
            break
        }
    }

    override func stopLoading() {
        Self.didStop = true
    }
}
