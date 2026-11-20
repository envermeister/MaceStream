import CryptoKit
import XCTest
@testable import MaceStream

final class OutpaceInstallerTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MaceStreamOutpaceTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        OutpaceURLProtocol.responder = nil
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testCurrentReleaseHasPinnedArchitectureAndChecksum() {
        let release = OutpaceRelease.current
        XCTAssertEqual(release.version, "1.2.1")
        XCTAssertEqual(release.sha256.count, 64)
        XCTAssertTrue(release.archiveName.contains("apple-darwin"))
        XCTAssertTrue(release.downloadURL.absoluteString.contains("/v1.2.1/"))
        XCTAssertEqual(release.archiveRoot, String(release.archiveName.dropLast(".tar.gz".count)))
    }

    func testInstallsVerifiedArchiveAndReusesInstallation() async throws {
        let fixture = try makeArchive()
        OutpaceURLProtocol.responder = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, fixture.data)
        }
        let paths = makePaths()
        let release = OutpaceRelease(version: "9.9.9", archiveName: "outpace-test.tar.gz", sha256: fixture.sha256)
        let installer = OutpaceInstaller(paths: paths, session: makeSession(), release: release)

        let executable = try await installer.install()

        XCTAssertEqual(executable, paths.outpaceExecutableURL)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.outpaceLicenseURL.path))
        let version = try String(contentsOf: paths.outpaceVersionURL, encoding: .utf8)
        XCTAssertEqual(version.trimmingCharacters(in: .whitespacesAndNewlines), "9.9.9")

        OutpaceURLProtocol.responder = nil
        let reused = try await installer.install()
        XCTAssertEqual(reused, executable)
    }

    func testRejectsChecksumMismatch() async throws {
        OutpaceURLProtocol.responder = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("not a valid release".utf8))
        }
        let installer = OutpaceInstaller(paths: makePaths(), session: makeSession())

        do {
            _ = try await installer.install()
            XCTFail("Expected the checksum mismatch to be rejected")
        } catch let error as OutpaceInstallerError {
            XCTAssertEqual(error, .checksumMismatch)
        }
    }

    private func makePaths() -> SupportPaths {
        SupportPaths(
            supportDirectory: root.appendingPathComponent("Support"),
            cacheDirectory: root.appendingPathComponent("Cache"),
            logsDirectory: root.appendingPathComponent("Logs")
        )
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OutpaceURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeArchive() throws -> (data: Data, sha256: String) {
        let source = root.appendingPathComponent("outpace-test", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let executable = source.appendingPathComponent("outpace")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data("Test license\n".utf8).write(to: source.appendingPathComponent("LICENSE"))
        let archive = root.appendingPathComponent("outpace-test.tar.gz")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-czf", archive.path, "-C", root.path, "outpace-test"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let data = try Data(contentsOf: archive)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (data, digest)
    }
}

private final class OutpaceURLProtocol: URLProtocol {
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
