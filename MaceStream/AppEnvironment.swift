import AppKit
import Foundation

@MainActor
final class AppEnvironment: ObservableObject {
    let paths: SupportPaths
    let settings: SettingsStore
    let history: HistoryStore
    let engine: EngineController
    let playback: PlaybackController
    weak var playerWindow: NSWindow?

    init(paths: SupportPaths = .production) {
        let resolvedPaths: SupportPaths
        if let captureRoot = ProcessInfo.processInfo.environment["MACESTREAM_CAPTURE_FRAMES"] {
            let state = URL(fileURLWithPath: captureRoot, isDirectory: true)
                .appendingPathComponent("CaptureState", isDirectory: true)
            resolvedPaths = SupportPaths(
                supportDirectory: state.appendingPathComponent("Support", isDirectory: true),
                cacheDirectory: state.appendingPathComponent("Cache", isDirectory: true),
                logsDirectory: state.appendingPathComponent("Logs", isDirectory: true)
            )
        } else {
            resolvedPaths = paths
        }
        self.paths = resolvedPaths
        settings = SettingsStore(paths: resolvedPaths)
        history = HistoryStore(paths: resolvedPaths)
        engine = EngineController(paths: resolvedPaths)
        playback = PlaybackController(engine: engine, settings: settings, history: history)
        AppDelegate.environment = self
    }

    func start() async {
        guard ProcessInfo.processInfo.environment["MACESTREAM_CAPTURE_DIR"] == nil,
              ProcessInfo.processInfo.environment["MACESTREAM_TESTS"] != "1",
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              NSClassFromString("XCTestCase") == nil else { return }
        await engine.start()
    }

    func restartEngine() async {
        playback.stop()
        await engine.restart()
    }

    func clearEngineCache() async {
        playback.stop()
        await engine.clearCacheAndRestart()
    }

    func shutdown() async {
        await playback.shutdown()
        await engine.stop()
    }

    func toggleFullScreen() {
        playerWindow?.toggleFullScreen(nil)
    }

    func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        let opened = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        if !opened {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    func revealLogs() {
        engine.revealLogs()
    }

    func copyDiagnostics() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        let report = """
        MaceStream \(version) (\(build))
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Engine: \(engine.status.message)
        Engine version: \(engine.status.version ?? "—")
        Local endpoint: \(engine.status.detail ?? "—")
        Playback phase: \(playback.phase)
        Playback error: \(playback.errorMessage ?? "—")
        Video: \(playback.videoDescription ?? "—")
        Peers: \(playback.statistics.peers)
        Download: \(playback.statistics.formattedDownloadSpeed)
        AVPlayer buffer: \(playback.bufferDescription)
        AVPlayer stall count: \(playback.mediaStallCount)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }
}
