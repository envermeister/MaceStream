import XCTest
@testable import MaceStream

@MainActor
final class HistoryStoreTests: XCTestCase {
    private var root: URL!
    private var paths: SupportPaths!

    override func setUp() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MaceStreamTests-\(UUID().uuidString)", isDirectory: true)
        paths = SupportPaths(
            supportDirectory: root.appendingPathComponent("Support"),
            cacheDirectory: root.appendingPathComponent("Cache"),
            logsDirectory: root.appendingPathComponent("Logs")
        )
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testRecordDeduplicatesAndIncrementsPlayCount() {
        let store = HistoryStore(paths: paths)
        let link = AceStreamLink(rawValue: "0123456789abcdef0123456789abcdef01234567")!
        store.record(link)
        store.record(link)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items[0].playCount, 2)
    }

    func testFavoriteIsPinnedAndPersisted() {
        let store = HistoryStore(paths: paths)
        let first = AceStreamLink(rawValue: "0123456789abcdef0123456789abcdef01234567")!
        let second = AceStreamLink(rawValue: "fedcba9876543210fedcba9876543210fedcba98")!
        store.record(first)
        store.record(second)
        store.toggleFavorite(store.items.first { $0.contentID == first.contentID }!)

        XCTAssertEqual(store.items.first?.contentID, first.contentID)
        let restored = HistoryStore(paths: paths)
        XCTAssertEqual(restored.items.first?.isFavorite, true)
        XCTAssertEqual(restored.items.count, 2)
    }

    func testRenameAndClear() {
        let store = HistoryStore(paths: paths)
        let link = AceStreamLink(rawValue: "0123456789abcdef0123456789abcdef01234567")!
        store.record(link)
        store.rename(store.items[0], to: "Test Stream")
        XCTAssertEqual(store.items[0].displayTitle, "Test Stream")
        store.rename(store.items[0], to: " ")
        XCTAssertNil(store.items[0].customTitle)
        store.clear()
        XCTAssertTrue(store.items.isEmpty)
    }
}
