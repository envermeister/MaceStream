import XCTest
@testable import MaceStream

final class AceStreamLinkTests: XCTestCase {
    private let id = "0123456789abcdef0123456789abcdef01234567"

    func testRawContentIDIsNormalized() {
        let link = AceStreamLink(rawValue: "  \(id.uppercased())\n")
        XCTAssertEqual(link?.contentID, id)
        XCTAssertEqual(link?.url.absoluteString, "acestream://\(id)")
    }

    func testAceStreamURL() {
        XCTAssertEqual(AceStreamLink(rawValue: "acestream://\(id)")?.contentID, id)
        XCTAssertEqual(AceStreamLink(rawValue: "acestream://\(id)/")?.contentID, id)
    }

    func testQueryURL() {
        XCTAssertEqual(AceStreamLink(rawValue: "acestream://?id=\(id)")?.contentID, id)
        XCTAssertEqual(AceStreamLink(rawValue: "acestream://?content_id=\(id)")?.contentID, id)
    }

    func testQuotedInput() {
        XCTAssertEqual(AceStreamLink(rawValue: "\"\(id)\"")?.contentID, id)
    }

    func testRejectsInvalidInput() {
        XCTAssertNil(AceStreamLink(rawValue: ""))
        XCTAssertNil(AceStreamLink(rawValue: String(id.dropLast())))
        XCTAssertNil(AceStreamLink(rawValue: String(repeating: "g", count: 40)))
        XCTAssertNil(AceStreamLink(rawValue: "https://example.com/\(id)"))
        XCTAssertNil(AceStreamLink(rawValue: "acestream://example.com"))
    }

    func testShortID() {
        let link = AceStreamLink(rawValue: id)
        XCTAssertEqual(link?.shortID, "01234567…4567")
    }
}
