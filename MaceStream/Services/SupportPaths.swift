import Foundation

struct SupportPaths: Sendable {
    let supportDirectory: URL
    let cacheDirectory: URL
    let logsDirectory: URL

    static let production = SupportPaths(
        supportDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MaceStream", isDirectory: true),
        cacheDirectory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MaceStream/AceStream", isDirectory: true),
        logsDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MaceStream/Logs", isDirectory: true)
    )

    var settingsURL: URL { supportDirectory.appendingPathComponent("settings.json") }
    var historyURL: URL { supportDirectory.appendingPathComponent("history.json") }
    var engineLogURL: URL { logsDirectory.appendingPathComponent("engine.log") }
    var serialLogURL: URL { logsDirectory.appendingPathComponent("vm-serial.log") }

    func createDirectories() throws {
        for url in [supportDirectory, cacheDirectory, logsDirectory] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
