import AppKit
import SwiftUI

struct PlayerView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var playback: PlaybackController
    @EnvironmentObject private var settings: SettingsStore

    let isFullScreen: Bool
    @State private var controlsVisible = true
    @State private var pointerOverControls = false
    @State private var hideControlsTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black

            if playback.hasActiveStream {
                #if DEBUG
                if playback.isShowingCapturePreview {
                    CaptureArtworkView()
                } else {
                    NativeVideoView(
                        player: playback.player,
                        aspectMode: settings.value.aspectMode
                    )
                }
                #else
                NativeVideoView(
                    player: playback.player,
                    aspectMode: settings.value.aspectMode
                )
                #endif
            }

            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    environment.toggleFullScreen()
                }

            if !playback.hasActiveStream {
                IdlePlayerView()
            } else {
                if showsControls {
                    VStack {
                        PlayerTopOverlay()
                        Spacer()
                    }
                    .transition(.opacity)
                }

                if playback.isBusy {
                    BufferingOverlay()
                }

                if playback.phase == .failed {
                    PlaybackErrorOverlay()
                }

                VStack {
                    Spacer()
                    if showsControls && playback.phase != .failed {
                        PlayerControlsView(isFullScreen: isFullScreen)
                            .padding(.horizontal, isFullScreen ? 24 : 14)
                            .padding(.bottom, isFullScreen ? 28 : 14)
                            .onHover { hovering in
                                pointerOverControls = hovering
                                if hovering { revealControls() }
                            }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: isFullScreen ? 0 : 18, style: .continuous))
        .overlay {
            if !isFullScreen {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            }
        }
        .onContinuousHover { phase in
            if case .active = phase { revealControls() }
        }
        .onChange(of: isFullScreen) { fullScreen in
            if fullScreen {
                revealControls()
            } else {
                hideControlsTask?.cancel()
                controlsVisible = true
                NSCursor.unhide()
            }
        }
        .onDisappear {
            hideControlsTask?.cancel()
            NSCursor.unhide()
        }
        .animation(.easeOut(duration: 0.18), value: controlsVisible)
    }

    private var showsControls: Bool {
        !isFullScreen || controlsVisible
    }

    private func revealControls() {
        controlsVisible = true
        NSCursor.unhide()
        hideControlsTask?.cancel()
        guard isFullScreen else { return }
        hideControlsTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, !pointerOverControls, playback.phase == .playing else { return }
            controlsVisible = false
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }
}

private struct IdlePlayerView: View {
    var body: some View {
        VStack(spacing: 17) {
            ZStack {
                Circle()
                    .fill(MaceStreamTheme.accent.opacity(0.07))
                    .frame(width: 92, height: 92)
                Circle()
                    .stroke(MaceStreamTheme.accent.opacity(0.16), lineWidth: 1)
                    .frame(width: 92, height: 92)
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 35, weight: .medium))
                    .foregroundStyle(MaceStreamTheme.accent)
            }
            VStack(spacing: 7) {
                Text("MaceStream")
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                    .foregroundStyle(MaceStreamTheme.primaryText)
                Text("Enter an AceStream link or choose one from history.")
                    .font(.callout)
                    .foregroundStyle(MaceStreamTheme.secondaryText)
            }
            HStack(spacing: 8) {
                Label("AVFoundation", systemImage: "cpu")
                Text("·")
                Label("Local engine", systemImage: "lock.shield")
                Text("·")
                Label("No search", systemImage: "magnifyingglass")
                    .foregroundStyle(MaceStreamTheme.secondaryText.opacity(0.7))
            }
            .font(.caption)
            .foregroundStyle(MaceStreamTheme.secondaryText)
        }
        .padding(30)
    }
}

private struct PlayerTopOverlay: View {
    @EnvironmentObject private var playback: PlaybackController
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(playback.displayTitle ?? "AceStream")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text("LIVE")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(MaceStreamTheme.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(MaceStreamTheme.accent.opacity(0.12), in: Capsule())
                }
                if let currentLink = playback.currentLink {
                    Text(currentLink.shortID)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(MaceStreamTheme.secondaryText)
                }
            }
            .padding(12)
            .background(.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 11))
            Spacer()
            if settings.value.showsStatistics {
                VStack(alignment: .trailing, spacing: 5) {
                    Label(playback.statistics.formattedDownloadSpeed, systemImage: "arrow.down.circle")
                    Label("\(playback.statistics.peers) peer", systemImage: "person.2")
                    Label("AV \(playback.bufferDescription)", systemImage: "cylinder")
                    if let notice = playback.notice {
                        Text(notice)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.trailing)
                    }
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .padding(12)
                .background(.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 11))
            }
        }
        .padding(16)
    }
}

private struct BufferingOverlay: View {
    @EnvironmentObject private var playback: PlaybackController

    var body: some View {
        ZStack {
            Color.black.opacity(0.34)
            VStack(spacing: 15) {
                ProgressView()
                    .controlSize(.large)
                    .tint(MaceStreamTheme.accent)
                Text(playback.phase == .connecting ? "Connecting to stream" : "Preparing stream")
                    .font(.headline)
                Text(playback.notice ?? playback.statistics.statusLabel)
                    .font(.callout)
                    .foregroundStyle(MaceStreamTheme.secondaryText)
                    .multilineTextAlignment(.center)
                if playback.statistics.progress > 0 {
                    VStack(spacing: 6) {
                        ProgressView(value: playback.statistics.progress, total: 100)
                            .tint(MaceStreamTheme.accent)
                        Text("Engine buffer \(Int(playback.statistics.progress))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(MaceStreamTheme.secondaryText)
                    }
                    .frame(width: 230)
                }
                if playback.statistics.peers > 0 || playback.statistics.downloadSpeed > 0 {
                    Text("\(playback.statistics.peers) peer  ·  \(playback.statistics.formattedDownloadSpeed)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(MaceStreamTheme.secondaryText)
                }
                Button("Cancel") { playback.stop() }
                    .buttonStyle(.bordered)
                    .padding(.top, 3)
            }
            .padding(26)
            .frame(width: 340)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.white.opacity(0.12))
            }
        }
    }
}

private struct PlaybackErrorOverlay: View {
    @EnvironmentObject private var playback: PlaybackController

    var body: some View {
        ZStack {
            Color.black.opacity(0.82)
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(MaceStreamTheme.danger)
                Text("Unable to play stream")
                    .font(.title3.weight(.semibold))
                Text(playback.errorMessage ?? "An unknown playback error occurred.")
                    .font(.callout)
                    .foregroundStyle(MaceStreamTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 520)
                Text("The stream may be offline, or its codec/container may not be supported by AVFoundation on this version of macOS.")
                    .font(.caption)
                    .foregroundStyle(MaceStreamTheme.secondaryText.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                HStack(spacing: 10) {
                    Button("Close") { playback.stop() }
                        .buttonStyle(.bordered)
                    Button {
                        playback.retry()
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MaceStreamTheme.accent)
                }
                .padding(.top, 5)
            }
            .padding(32)
        }
    }
}
