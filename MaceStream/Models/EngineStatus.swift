import Foundation

enum EnginePhase: Equatable, Sendable {
    case stopped
    case starting
    case ready
    case failed
    case stopping
}

struct EngineStatus: Equatable, Sendable {
    var phase: EnginePhase = .stopped
    var message: String = "Engine stopped"
    var detail: String?
    var version: String?
    var endpoint: EngineEndpoint?

    var isReady: Bool { phase == .ready }
}
