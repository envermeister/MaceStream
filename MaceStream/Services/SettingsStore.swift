import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    @Published private(set) var value: AppSettings
    @Published private(set) var persistenceError: String?

    private let paths: SupportPaths

    init(paths: SupportPaths = .production) {
        self.paths = paths
        if let data = try? Data(contentsOf: paths.settingsURL),
           let settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
            value = settings
        } else {
            value = .default
        }
    }

    func update(_ change: (inout AppSettings) -> Void) {
        let previous = value
        change(&value)
        do {
            try persist()
            persistenceError = nil
        } catch {
            value = previous
            persistenceError = "Could not save settings: \(error.localizedDescription)"
        }
    }

    func resetPlaybackSettings() {
        update { settings in
            let defaults = AppSettings.default
            settings.bufferProfile = defaults.bufferProfile
            settings.customBufferSeconds = defaults.customBufferSeconds
            settings.automaticallyWaitsToMinimizeStalling = defaults.automaticallyWaitsToMinimizeStalling
            settings.keepsLiveStreamActiveWhilePaused = defaults.keepsLiveStreamActiveWhilePaused
            settings.showsStatistics = defaults.showsStatistics
            settings.aspectMode = defaults.aspectMode
        }
    }

    private func persist() throws {
        try paths.createDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: paths.settingsURL, options: .atomic)
    }
}
