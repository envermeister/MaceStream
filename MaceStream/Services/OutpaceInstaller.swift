import CryptoKit
import Foundation

struct OutpaceRelease {
    let version: String
    let archiveName: String
    let sha256: String

    var downloadURL: URL {
        URL(string: "https://github.com/outpace-stream/outpace-engine/releases/download/v\(version)/\(archiveName)")!
    }

    var archiveRoot: String {
        String(archiveName.dropLast(".tar.gz".count))
    }

    static let current = OutpaceRelease(
        version: "1.2.1",
        archiveName: archiveName,
        sha256: archiveSHA256
    )

    static let projectURL = URL(string: "https://github.com/outpace-stream/outpace-engine")!
    static let licenseURL = URL(string: "https://github.com/outpace-stream/outpace-engine/blob/v1.2.1/LICENSE")!

    private static var archiveName: String {
        #if arch(arm64)
        "outpace-1.2.1-aarch64-apple-darwin.tar.gz"
        #else
        "outpace-1.2.1-x86_64-apple-darwin.tar.gz"
        #endif
    }

    private static var archiveSHA256: String {
        #if arch(arm64)
        "e6dbe4635d888f4eb6d620143fc19b0ecfa202caebcb10233c1d0d5dbed08e28"
        #else
        "3c913c383a375c0aa7a562f6d6ce2c9a9ad901f6d8f639c5ef10dabe69b45fb1"
        #endif
    }
}

struct OutpaceInstaller {
    private let paths: SupportPaths
    private let session: URLSession
    private let release: OutpaceRelease

    init(paths: SupportPaths, session: URLSession? = nil, release: OutpaceRelease = .current) {
        self.paths = paths
        self.release = release
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 120
            self.session = URLSession(configuration: configuration)
        }
    }

    func install() async throws -> URL {
        if let installedVersion = try? String(contentsOf: paths.outpaceVersionURL, encoding: .utf8),
           installedVersion.trimmingCharacters(in: .whitespacesAndNewlines) == release.version,
           FileManager.default.isExecutableFile(atPath: paths.outpaceExecutableURL.path) {
            return paths.outpaceExecutableURL
        }

        try paths.createDirectories()
        try FileManager.default.createDirectory(at: paths.outpaceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.outpaceDataDirectory, withIntermediateDirectories: true)
        try Task.checkCancellation()

        let (downloadedFile, response) = try await session.download(from: release.downloadURL)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw OutpaceInstallerError.downloadFailed
        }
        try Task.checkCancellation()
        let archive = try Data(contentsOf: downloadedFile)
        guard sha256Hex(archive) == release.sha256 else {
            throw OutpaceInstallerError.checksumMismatch
        }

        let extractionDirectory = paths.cacheDirectory
            .appendingPathComponent("outpace-extract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: extractionDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: extractionDirectory) }
        try extract(archive: downloadedFile, to: extractionDirectory)

        let sourceDirectory = extractionDirectory.appendingPathComponent(release.archiveRoot, isDirectory: true)
        let executable = sourceDirectory.appendingPathComponent("outpace")
        let license = sourceDirectory.appendingPathComponent("LICENSE")
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              FileManager.default.fileExists(atPath: license.path) else {
            throw OutpaceInstallerError.invalidArchive
        }

        try replaceItem(at: paths.outpaceExecutableURL, with: executable)
        try replaceItem(at: paths.outpaceLicenseURL, with: license)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.outpaceExecutableURL.path)
        try Data("\(release.version)\n".utf8).write(to: paths.outpaceVersionURL, options: .atomic)
        return paths.outpaceExecutableURL
    }

    private func extract(archive: URL, to directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", archive.path, "-C", directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw OutpaceInstallerError.extractionFailed
        }
        guard process.terminationStatus == 0 else {
            throw OutpaceInstallerError.extractionFailed
        }
    }

    private func replaceItem(at destination: URL, with source: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum OutpaceInstallerError: LocalizedError {
    case downloadFailed
    case checksumMismatch
    case extractionFailed
    case invalidArchive

    var errorDescription: String? {
        switch self {
        case .downloadFailed:
            return "Could not download Outpace. Check your internet connection and try again."
        case .checksumMismatch:
            return "The downloaded Outpace archive did not match the expected SHA-256 checksum."
        case .extractionFailed:
            return "The downloaded Outpace archive could not be extracted."
        case .invalidArchive:
            return "The downloaded Outpace archive did not contain the expected executable and license."
        }
    }
}
