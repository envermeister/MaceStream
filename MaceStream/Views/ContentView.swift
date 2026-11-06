import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var playback: PlaybackController

    @State private var input = ""
    @State private var validationError: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isFullScreen = false
    @State private var isDropTargeted = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            HistorySidebarView { item in
                play(item.link, title: item.displayTitle)
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 310)
        } detail: {
            VStack(spacing: 0) {
                if !isFullScreen {
                    LinkEntryView(
                        text: $input,
                        validationError: $validationError,
                        onPlay: playInput
                    )
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 4)
                }

                PlayerView(isFullScreen: isFullScreen)
                    .padding(isFullScreen ? 0 : 14)

                if !isFullScreen {
                    StatusBarView()
                        .padding(.horizontal, 18)
                        .padding(.bottom, 10)
                }
            }
            .background(isFullScreen ? Color.black : MaceStreamTheme.background)
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(MaceStreamTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [8]))
                        .padding(8)
                    Text("Drop a link to play")
                        .font(.headline)
                        .padding(16)
                        .background(.regularMaterial, in: Capsule())
                }
            }
            .onDrop(of: [UTType.text, UTType.plainText], isTargeted: $isDropTargeted, perform: handleDrop)
        }
        .background(MaceStreamTheme.background)
        .background {
            PlayerWindowConnector { environment.playerWindow = $0 }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !isFullScreen {
                    EngineToolbarMenu()
                    Button {
                        environment.openSettings()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .help("Settings (⌘,)")
                }
            }
        }
        .onOpenURL { url in
            input = url.absoluteString
            playInput()
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .maceStreamCaptureInput)) { _ in
            input = "acestream://0123456789abcdef0123456789abcdef01234567"
            validationError = nil
        }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { notification in
            guard let window = notification.object as? NSWindow, window === environment.playerWindow else { return }
            isFullScreen = true
            columnVisibility = .detailOnly
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { notification in
            guard let window = notification.object as? NSWindow, window === environment.playerWindow else { return }
            isFullScreen = false
            columnVisibility = .all
            NSCursor.unhide()
        }
    }

    private func playInput() {
        guard let link = AceStreamLink(rawValue: input) else {
            validationError = "Enter a valid acestream:// link or 40-character content ID."
            NSSound.beep()
            return
        }
        play(link)
    }

    private func play(_ link: AceStreamLink, title: String? = nil) {
        validationError = nil
        input = link.url.absoluteString
        playback.play(link, title: title)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String else { return }
            Task { @MainActor in
                input = string
                playInput()
            }
        }
        return true
    }
}

private struct PlayerWindowConnector: NSViewRepresentable {
    final class View: NSView {
        var onWindowChange: (NSWindow?) -> Void = { _ in }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { self.onWindowChange(self.window) }
        }
    }

    let onWindowChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> View {
        let view = View()
        view.onWindowChange = onWindowChange
        return view
    }

    func updateNSView(_ view: View, context: Context) {
        view.onWindowChange = onWindowChange
        DispatchQueue.main.async { view.onWindowChange(view.window) }
    }
}

private struct EngineToolbarMenu: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var engine: EngineController

    var body: some View {
        Menu {
            Label(engine.status.message, systemImage: "cpu")
            if let version = engine.status.version {
                Text("AceStream \(version)")
            }
            if let detail = engine.status.detail {
                Text(detail)
                    .font(.caption)
            }
            Divider()
            Button("Restart Engine") {
                Task { await environment.restartEngine() }
            }
            Button("Show Logs") {
                environment.revealLogs()
            }
        } label: {
            HStack(spacing: 7) {
                if engine.status.phase == .starting {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.65)
                        .frame(width: 10, height: 10)
                } else {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                }
                Text(engine.status.phase == .ready ? "Engine ready" : "Engine")
                    .font(.callout)
            }
        }
        .menuStyle(.borderlessButton)
        .help(engine.status.detail ?? engine.status.message)
    }

    private var statusColor: Color {
        switch engine.status.phase {
        case .ready: return MaceStreamTheme.accent
        case .failed: return MaceStreamTheme.danger
        case .starting: return .orange
        case .stopped, .stopping: return MaceStreamTheme.secondaryText
        }
    }
}
