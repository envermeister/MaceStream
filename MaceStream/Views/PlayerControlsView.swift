import SwiftUI

struct PlayerControlsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var playback: PlaybackController
    @EnvironmentObject private var settings: SettingsStore
    let isFullScreen: Bool

    var body: some View {
        HStack(spacing: 7) {
            PlayerControlButton(
                icon: showsPause ? "pause.fill" : "play.fill",
                help: showsPause ? "Pause (Space)" : "Play (Space)",
                prominent: true
            ) {
                playback.togglePlayPause()
            }

            PlayerControlButton(icon: "stop.fill", help: "Stop Stream") {
                playback.stop()
            }

            Divider()
                .frame(height: 24)
                .padding(.horizontal, 3)

            Menu {
                ForEach(playback.audioTracks) { track in
                    Button {
                        playback.selectAudioTrack(track)
                    } label: {
                        HStack {
                            Text(track.title)
                            if playback.selectedAudioTrackID == track.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                PlayerControlLabel(icon: "speaker.wave.2", active: false)
            }
            .menuStyle(.borderlessButton)
            .disabled(playback.audioTracks.count < 2)
            .help(playback.audioTracks.count < 2 ? "No alternative audio tracks" : "Audio tracks")

            Menu {
                Button {
                    playback.selectSubtitleTrack(nil)
                } label: {
                    HStack {
                        Text("Off")
                        if playback.selectedSubtitleTrackID == nil {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                ForEach(playback.subtitleTracks) { track in
                    Button {
                        playback.selectSubtitleTrack(track)
                    } label: {
                        HStack {
                            Text(track.title)
                            if playback.selectedSubtitleTrackID == track.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                PlayerControlLabel(icon: "captions.bubble", active: playback.selectedSubtitleTrackID != nil)
            }
            .menuStyle(.borderlessButton)
            .disabled(playback.subtitleTracks.isEmpty)
            .help(playback.subtitleTracks.isEmpty ? "No subtitle tracks" : "Subtitles")

            PlayerControlButton(
                icon: settings.value.aspectMode == .fit ? "rectangle.arrowtriangle.2.outward" : "rectangle.arrowtriangle.2.inward",
                help: "Video: \(settings.value.aspectMode.title)"
            ) {
                settings.update { settings in
                    settings.aspectMode = settings.aspectMode == .fit ? .fill : .fit
                }
            }

            PlayerControlButton(
                icon: settings.value.showsStatistics ? "chart.bar.fill" : "chart.bar",
                help: "Stream statistics",
                active: settings.value.showsStatistics
            ) {
                settings.update { $0.showsStatistics.toggle() }
            }

            Spacer(minLength: 8)

            PlayerControlButton(
                icon: playback.isMuted || playback.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                help: playback.isMuted ? "Unmute (M)" : "Mute (M)"
            ) {
                playback.toggleMute()
            }

            Slider(
                value: Binding(
                    get: { playback.volume },
                    set: { playback.setVolume($0) }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    if !editing { playback.setVolume(playback.volume, persist: true) }
                }
            )
            .frame(width: 92)
            .tint(MaceStreamTheme.accent)
            .help("Volume")

            Text("\(Int((playback.volume * 100).rounded()))%")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(MaceStreamTheme.secondaryText)
                .frame(width: 34, alignment: .trailing)

            PlayerControlButton(
                icon: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                help: isFullScreen ? "Exit Full Screen (F)" : "Full Screen (F / Double-click)"
            ) {
                environment.toggleFullScreen()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
    }

    private var showsPause: Bool {
        playback.phase == .playing || playback.phase == .buffering
    }
}

struct PlayerControlLabel: View {
    let icon: String
    var active = false

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(active ? MaceStreamTheme.accent : Color.white.opacity(0.88))
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
    }
}

struct PlayerControlButton: View {
    let icon: String
    let help: String
    var prominent = false
    var active = false
    let action: () -> Void

    init(
        icon: String,
        help: String,
        prominent: Bool = false,
        active: Bool = false,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.help = help
        self.prominent = prominent
        self.active = active
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(prominent ? Color(hex: 0x09261F) : active ? MaceStreamTheme.accent : Color.white.opacity(0.88))
                .frame(width: 32, height: 32)
                .background {
                    if prominent {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(MaceStreamTheme.accent)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
