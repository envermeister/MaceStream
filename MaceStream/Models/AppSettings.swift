import Foundation

enum BufferProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case lowLatency
    case balanced
    case stable
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .lowLatency: return "Low Latency"
        case .balanced: return "Balanced"
        case .stable: return "High Stability"
        case .custom: return "Custom"
        }
    }

    var subtitle: String {
        switch self {
        case .automatic: return "AVPlayer adapts to network conditions"
        case .lowLatency: return "2-second target buffer"
        case .balanced: return "8-second target buffer"
        case .stable: return "20-second target buffer"
        case .custom: return "Custom target duration"
        }
    }

    var targetSeconds: Double? {
        switch self {
        case .automatic: return nil
        case .lowLatency: return 2
        case .balanced: return 8
        case .stable: return 20
        case .custom: return nil
        }
    }
}

enum VideoAspectMode: String, Codable, CaseIterable, Sendable {
    case fit
    case fill

    var title: String {
        switch self {
        case .fit: return "Fit"
        case .fill: return "Fill"
        }
    }
}

struct AppSettings: Codable, Equatable, Sendable {
    var bufferProfile: BufferProfile
    var customBufferSeconds: Double
    var automaticallyWaitsToMinimizeStalling: Bool
    var keepsLiveStreamActiveWhilePaused: Bool
    var volume: Double
    var isMuted: Bool
    var showsStatistics: Bool
    var aspectMode: VideoAspectMode

    static let `default` = AppSettings(
        bufferProfile: .balanced,
        customBufferSeconds: 12,
        automaticallyWaitsToMinimizeStalling: true,
        keepsLiveStreamActiveWhilePaused: true,
        volume: 0.8,
        isMuted: false,
        showsStatistics: true,
        aspectMode: .fit
    )

    var playerBufferSeconds: Double {
        if bufferProfile == .custom {
            return customBufferSeconds.clamped(to: 1...60)
        }
        return bufferProfile.targetSeconds ?? 0
    }

    init(
        bufferProfile: BufferProfile,
        customBufferSeconds: Double,
        automaticallyWaitsToMinimizeStalling: Bool,
        keepsLiveStreamActiveWhilePaused: Bool,
        volume: Double,
        isMuted: Bool,
        showsStatistics: Bool,
        aspectMode: VideoAspectMode
    ) {
        self.bufferProfile = bufferProfile
        self.customBufferSeconds = customBufferSeconds
        self.automaticallyWaitsToMinimizeStalling = automaticallyWaitsToMinimizeStalling
        self.keepsLiveStreamActiveWhilePaused = keepsLiveStreamActiveWhilePaused
        self.volume = volume
        self.isMuted = isMuted
        self.showsStatistics = showsStatistics
        self.aspectMode = aspectMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.default
        bufferProfile = try container.decodeIfPresent(BufferProfile.self, forKey: .bufferProfile) ?? defaults.bufferProfile
        customBufferSeconds = try container.decodeIfPresent(Double.self, forKey: .customBufferSeconds) ?? defaults.customBufferSeconds
        automaticallyWaitsToMinimizeStalling = try container.decodeIfPresent(Bool.self, forKey: .automaticallyWaitsToMinimizeStalling) ?? defaults.automaticallyWaitsToMinimizeStalling
        keepsLiveStreamActiveWhilePaused = try container.decodeIfPresent(Bool.self, forKey: .keepsLiveStreamActiveWhilePaused) ?? defaults.keepsLiveStreamActiveWhilePaused
        volume = (try container.decodeIfPresent(Double.self, forKey: .volume) ?? defaults.volume).clamped(to: 0...1)
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? defaults.isMuted
        showsStatistics = try container.decodeIfPresent(Bool.self, forKey: .showsStatistics) ?? defaults.showsStatistics
        aspectMode = try container.decodeIfPresent(VideoAspectMode.self, forKey: .aspectMode) ?? defaults.aspectMode
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
