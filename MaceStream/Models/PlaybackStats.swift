import Foundation

struct PlaybackStats: Equatable, Sendable {
    var status: String = ""
    var progress: Double = 0
    var downloadSpeed: Double = 0
    var uploadSpeed: Double = 0
    var peers: Int = 0
    var downloadedBytes: UInt64 = 0
    var uploadedBytes: UInt64 = 0

    static let empty = PlaybackStats()

    var isDownloading: Bool {
        status == "dl" || status == "downloading"
    }

    var isPrebuffering: Bool { !isDownloading }

    var statusLabel: String {
        switch status {
        case "dl", "downloading": return "Receiving stream"
        case "prebuf", "prebuffering", "prefuf": return "Filling engine buffer"
        case "waiting": return "Waiting for source"
        case "": return "Connecting to engine"
        default: return status
        }
    }

    var formattedDownloadSpeed: String {
        Self.formatSpeed(downloadSpeed)
    }

    var formattedUploadSpeed: String {
        Self.formatSpeed(uploadSpeed)
    }

    private static func formatSpeed(_ kilobytesPerSecond: Double) -> String {
        if kilobytesPerSecond >= 1024 {
            return String(format: "%.1f MB/s", kilobytesPerSecond / 1024)
        }
        return String(format: "%.0f KB/s", kilobytesPerSecond)
    }
}
