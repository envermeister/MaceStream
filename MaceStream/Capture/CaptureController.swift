#if DEBUG
import AppKit
import Foundation
import SwiftUI

@MainActor
final class CaptureController {
    private let environment: AppEnvironment
    private let outputDirectory: URL
    private let framesDirectory: URL
    private var frameIndex = 0
    private var isRecording = false
    private var captureSettingsWindow: NSWindow?

    private init(environment: AppEnvironment, outputDirectory: URL, framesDirectory: URL) {
        self.environment = environment
        self.outputDirectory = outputDirectory
        self.framesDirectory = framesDirectory
    }

    static func startIfNeeded(environment: AppEnvironment) {
        guard let output = ProcessInfo.processInfo.environment["MACESTREAM_CAPTURE_DIR"],
              let frames = ProcessInfo.processInfo.environment["MACESTREAM_CAPTURE_FRAMES"] else { return }
        let controller = CaptureController(
            environment: environment,
            outputDirectory: URL(fileURLWithPath: output, isDirectory: true),
            framesDirectory: URL(fileURLWithPath: frames, isDirectory: true)
        )
        Task { @MainActor in await controller.run() }
    }

    private func run() async {
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: framesDirectory.path) {
                try FileManager.default.removeItem(at: framesDirectory)
            }
            try FileManager.default.createDirectory(at: framesDirectory, withIntermediateDirectories: true)
        } catch {
            fputs("Capture setup failed: \(error)\n", stderr)
            exit(1)
        }

        environment.engine.presentForCapture()
        isRecording = true
        let recorder = Task { @MainActor in await recordFrames() }

        await pause(1.2)
        capture("01-home", of: environment.playerWindow)

        NotificationCenter.default.post(name: .maceStreamCaptureInput, object: nil)
        await pause(1.2)
        capture("02-link", of: environment.playerWindow)
        populateHistory()
        await pause(0.8)

        environment.playback.presentForCapture()
        await pause(1.8)
        capture("03-player", of: environment.playerWindow)

        presentSettingsWindow()
        await pause(1.4)
        capture("04-settings", of: settingsWindow)
        await pause(1.0)
        settingsWindow?.orderOut(nil)
        environment.playerWindow?.makeKeyAndOrderFront(nil)
        await pause(0.8)

        isRecording = false
        await recorder.value
        exit(0)
    }

    private func populateHistory() {
        let main = AceStreamLink(rawValue: "0123456789abcdef0123456789abcdef01234567")!
        let second = AceStreamLink(rawValue: "fedcba9876543210fedcba9876543210fedcba98")!
        let third = AceStreamLink(rawValue: "00112233445566778899aabbccddeeff00112233")!
        environment.history.record(second)
        environment.history.record(third)
        environment.history.record(main)
        if let item = environment.history.items.first(where: { $0.contentID == second.contentID }) {
            environment.history.rename(item, to: "Football Highlights · Sample")
            environment.history.toggleFavorite(item)
        }
        if let item = environment.history.items.first(where: { $0.contentID == third.contentID }) {
            environment.history.rename(item, to: "Evening News · Sample")
        }
        if let item = environment.history.items.first(where: { $0.contentID == main.contentID }) {
            environment.history.rename(item, to: "Sports Replay · Sample")
        }
    }

    private func recordFrames() async {
        while isRecording {
            let window = settingsWindow ?? environment.playerWindow
            let name = String(format: "frame-%03d", frameIndex)
            frameIndex += 1
            capture(name, of: window, directory: framesDirectory)
            await pause(0.25)
        }
    }

    private var settingsWindow: NSWindow? { captureSettingsWindow }

    private func presentSettingsWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 610, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.contentView = NSHostingView(
            rootView: SettingsView()
                .environmentObject(environment)
                .environmentObject(environment.settings)
                .environmentObject(environment.engine)
                .environmentObject(environment.playback)
        )
        window.center()
        captureSettingsWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    private func capture(_ name: String, of window: NSWindow?, directory: URL? = nil) {
        guard let window, let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        let url = (directory ?? outputDirectory).appendingPathComponent("\(name).png")
        try? data.write(to: url)
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

extension Notification.Name {
    static let maceStreamCaptureInput = Notification.Name("MaceStreamCaptureInput")
}
#endif
