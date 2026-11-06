import SwiftUI

@main
struct MaceStreamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup("MaceStream") {
            ContentView()
                .environmentObject(environment)
                .environmentObject(environment.settings)
                .environmentObject(environment.history)
                .environmentObject(environment.engine)
                .environmentObject(environment.playback)
                .frame(minWidth: 960, minHeight: 620)
                .task {
                    await environment.start()
                    #if DEBUG
                    CaptureController.startIfNeeded(environment: environment)
                    #endif
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1220, height: 780)
        .commands {
            CommandMenu("Playback") {
                Button(environment.playback.phase == .playing ? "Pause" : "Play") {
                    environment.playback.togglePlayPause()
                }
                .disabled(!environment.playback.canTogglePlayPause)

                Button("Stop Stream") {
                    environment.playback.stop()
                }
                .disabled(!environment.playback.hasActiveStream)
                .keyboardShortcut(".", modifiers: .command)

                Button(environment.playback.isMuted ? "Unmute" : "Mute") {
                    environment.playback.toggleMute()
                }
                .disabled(!environment.playback.hasActiveStream)
                .keyboardShortcut("m", modifiers: [.command, .shift])

                Divider()

                Button("Full Screen") {
                    environment.toggleFullScreen()
                }
                .keyboardShortcut("f", modifiers: [.command, .control])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(environment)
                .environmentObject(environment.settings)
                .environmentObject(environment.engine)
                .environmentObject(environment.playback)
        }
    }
}
