import XCTest
@testable import MaceStream

final class AppSettingsTests: XCTestCase {
    func testBufferProfiles() {
        var settings = AppSettings.default
        settings.bufferProfile = .automatic
        XCTAssertEqual(settings.playerBufferSeconds, 0)
        settings.bufferProfile = .lowLatency
        XCTAssertEqual(settings.playerBufferSeconds, 2)
        settings.bufferProfile = .balanced
        XCTAssertEqual(settings.playerBufferSeconds, 8)
        settings.bufferProfile = .stable
        XCTAssertEqual(settings.playerBufferSeconds, 20)
    }

    func testCustomBufferIsClamped() {
        var settings = AppSettings.default
        settings.bufferProfile = .custom
        settings.customBufferSeconds = 500
        XCTAssertEqual(settings.playerBufferSeconds, 60)
        settings.customBufferSeconds = -5
        XCTAssertEqual(settings.playerBufferSeconds, 1)
    }

    func testMissingFieldsUseDefaults() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings, .default)
    }

    func testEngineBackendRoundTrip() throws {
        var settings = AppSettings.default
        XCTAssertEqual(settings.engineBackend, .official)
        settings.engineBackend = .outpace
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data), settings)
    }

    func testVolumeIsClampedWhileDecoding() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{\"volume\":4}".utf8))
        XCTAssertEqual(settings.volume, 1)
    }
}
