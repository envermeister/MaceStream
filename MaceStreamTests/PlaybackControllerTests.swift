import XCTest
@testable import MaceStream

@MainActor
final class PlaybackControllerTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MaceStreamPlaybackTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testDuplicateFailuresScheduleOnlyOneRetry() {
        let paths = SupportPaths(
            supportDirectory: root.appendingPathComponent("Support"),
            cacheDirectory: root.appendingPathComponent("Cache"),
            logsDirectory: root.appendingPathComponent("Logs")
        )
        let settings = SettingsStore(paths: paths)
        let history = HistoryStore(paths: paths)
        let engine = EngineController(paths: paths)
        let playback = PlaybackController(engine: engine, settings: settings, history: history)
        playback.prepareForRetryTesting()

        playback.simulateFailureForTesting()
        playback.simulateFailureForTesting()
        playback.simulateFailureForTesting()

        XCTAssertTrue(playback.hasPendingRetryForTesting)
        XCTAssertEqual(playback.retryCountForTesting, 1)
        XCTAssertEqual(playback.phase, .buffering)
        playback.stop()
        XCTAssertFalse(playback.hasPendingRetryForTesting)
    }
}
