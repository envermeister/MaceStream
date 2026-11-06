import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var playback: PlaybackController

    var body: some View {
        TabView {
            PlayerSettingsTab()
                .tabItem { Label("Player", systemImage: "play.rectangle") }
            EngineSettingsTab()
                .tabItem { Label("Engine", systemImage: "cpu") }
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 610, height: 480)
        .background(MaceStreamTheme.background)
        .onChange(of: settings.value) { _ in playback.applySettings() }
    }
}

private struct PlayerSettingsTab: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Picker("Buffer profile", selection: bufferProfile) {
                    ForEach(BufferProfile.allCases) { profile in
                        Text(profile.title).tag(profile)
                    }
                }
                Text(settings.value.bufferProfile.subtitle)
                    .font(.caption)
                    .foregroundStyle(MaceStreamTheme.secondaryText)

                if settings.value.bufferProfile == .custom {
                    HStack {
                        Text("Target duration")
                        Slider(value: customBufferSeconds, in: 1...60, step: 1)
                        Text("\(Int(settings.value.customBufferSeconds)) s")
                            .monospacedDigit()
                            .frame(width: 45, alignment: .trailing)
                    }
                }

                Toggle(
                    "Automatically wait to minimize stalling",
                    isOn: binding(\.automaticallyWaitsToMinimizeStalling)
                )
                Text("AVPlayer waits until enough data is available before playing. Turn this off for lower latency, though stalling may be more likely.")
                    .font(.caption)
                    .foregroundStyle(MaceStreamTheme.secondaryText)

                Toggle(
                    "Keep receiving the live stream while paused",
                    isOn: binding(\.keepsLiveStreamActiveWhilePaused)
                )
            } header: {
                Text("Live stream buffer")
            } footer: {
                Text("The target duration is a preference passed to AVPlayer; actual buffering depends on the source and network conditions. The AceStream engine’s prebuffer is independent of this setting.")
                    .font(.caption)
                    .foregroundStyle(MaceStreamTheme.secondaryText)
            }

            Section("Display & Diagnostics") {
                Picker("Video layout", selection: binding(\.aspectMode)) {
                    ForEach(VideoAspectMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("Show stream statistics", isOn: binding(\.showsStatistics))
                Button("Reset Player Settings") {
                    settings.resetPlaybackSettings()
                }
            }

            if let error = settings.persistenceError {
                Text(error)
                    .foregroundStyle(MaceStreamTheme.danger)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .padding(12)
    }

    private var bufferProfile: Binding<BufferProfile> {
        binding(\.bufferProfile)
    }

    private var customBufferSeconds: Binding<Double> {
        binding(\.customBufferSeconds)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { settings.value[keyPath: keyPath] },
            set: { newValue in settings.update { $0[keyPath: keyPath] = newValue } }
        )
    }
}

private struct EngineSettingsTab: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var engine: EngineController
    @State private var confirmsCacheClear = false
    @State private var copiedDiagnostics = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: engine.status.isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(engine.status.isReady ? MaceStreamTheme.accent : .orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(engine.status.message)
                            .font(.headline)
                        Text(engine.status.detail ?? "Waiting for engine status…")
                            .font(.caption)
                            .foregroundStyle(MaceStreamTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)

                LabeledContent("Engine version", value: engine.status.version ?? "—")
                LabeledContent("Virtual machine", value: "Linux · 2 CPU · 512 MB")
                LabeledContent("Local transport", value: "127.0.0.1 + virtio-vsock · Random available port")

                HStack {
                    Button("Restart") {
                        Task { await environment.restartEngine() }
                    }
                    .disabled(engine.status.phase == .starting)
                    Button("Show Logs") {
                        environment.revealLogs()
                    }
                    Spacer()
                    Button("Clear Cache…", role: .destructive) {
                        confirmsCacheClear = true
                    }
                }
            } header: {
                Text("Embedded AceStream engine")
            } footer: {
                Text("Restarting stops the active stream. MaceStream only shuts down the VM it started and leaves other AceStream processes untouched.")
                    .font(.caption)
                    .foregroundStyle(MaceStreamTheme.secondaryText)
            }

            Section("Troubleshooting") {
                Text("Diagnostics include the app/macOS version, engine status, and player metrics. They do not include your link history.")
                    .font(.caption)
                    .foregroundStyle(MaceStreamTheme.secondaryText)
                HStack {
                    Button(copiedDiagnostics ? "Copied" : "Copy Diagnostics") {
                        environment.copyDiagnostics()
                        copiedDiagnostics = true
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            copiedDiagnostics = false
                        }
                    }
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .confirmationDialog(
            "Clear the engine cache?",
            isPresented: $confirmsCacheClear,
            titleVisibility: .visible
        ) {
            Button("Clear and Restart", role: .destructive) {
                Task { await environment.clearEngineCache() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The active stream will stop. Your history and settings will not be deleted.")
        }
    }
}

private struct GeneralSettingsTab: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var confirmsHistoryClear = false

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    var body: some View {
        Form {
            Section("Link History") {
                LabeledContent("Stored links", value: "\(environment.history.items.count)")
                Text("Up to 60 links, with names, favorite status, and play counts, are stored only in this Mac’s Application Support directory.")
                    .font(.caption)
                    .foregroundStyle(MaceStreamTheme.secondaryText)
                HStack {
                    Spacer()
                    Button("Clear All History…", role: .destructive) {
                        confirmsHistoryClear = true
                    }
                    .disabled(environment.history.items.isEmpty)
                }
            }

            Section("Privacy & Scope") {
                Label("No stream or content search", systemImage: "magnifyingglass")
                Label("No analytics, ads, or remote channel lists", systemImage: "hand.raised")
                Label("Only plays links provided by the user", systemImage: "link")
                    .font(.callout)
                Text("Because AceStream is peer-to-peer, other peers on the stream network may see your IP address during playback. Only open streams you are authorized to use.")
                    .font(.caption)
                    .foregroundStyle(MaceStreamTheme.secondaryText)
                    .padding(.top, 4)
            }

            Section("About") {
                LabeledContent("MaceStream", value: appVersion)
                LabeledContent("Player", value: "Apple AVFoundation / AVPlayer")
                LabeledContent("Distribution", value: "macOS 13+ · ARM64 + x86_64")
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .confirmationDialog(
            "Clear all link history?",
            isPresented: $confirmsHistoryClear,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                environment.history.clear()
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
