import SwiftUI

struct StatusBarView: View {
    @EnvironmentObject private var playback: PlaybackController

    var body: some View {
        HStack(spacing: 12) {
            if playback.hasActiveStream {
                Label("LIVE", systemImage: "dot.radiowaves.left.and.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(MaceStreamTheme.accent)
                Metric(icon: "person.2", value: "\(playback.statistics.peers) peer")
                Metric(icon: "arrow.down", value: playback.statistics.formattedDownloadSpeed)
                Metric(icon: "cylinder", value: "Buffer \(playback.bufferDescription)")
                if let video = playback.videoDescription {
                    Text(video)
                        .lineLimit(1)
                }
            } else {
                Image(systemName: "lock.shield")
                Text("No search, analytics, or remote channel lists. Your links stay on this Mac.")
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if playback.observedBitrate > 0 {
                Text(playback.formattedObservedBitrate)
                    .monospacedDigit()
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(MaceStreamTheme.secondaryText)
        .frame(height: 18)
    }
}

private struct Metric: View {
    let icon: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(value)
                .monospacedDigit()
        }
    }
}
