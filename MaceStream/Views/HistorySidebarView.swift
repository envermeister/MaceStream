import AppKit
import SwiftUI

struct HistorySidebarView: View {
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var playback: PlaybackController
    let onPlay: (HistoryItem) -> Void

    @State private var showsClearConfirmation = false

    private var favorites: [HistoryItem] { history.items.filter(\.isFavorite) }
    private var recent: [HistoryItem] { history.items.filter { !$0.isFavorite } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("My Links", systemImage: "play.rectangle.on.rectangle")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                if !history.items.isEmpty {
                    Text("\(history.items.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(MaceStreamTheme.secondaryText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.06), in: Capsule())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            if history.items.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(MaceStreamTheme.secondaryText.opacity(0.7))
                    Text("No links yet")
                        .font(.headline)
                    Text("Links you play are stored here\nonly on this Mac.")
                        .font(.caption)
                        .foregroundStyle(MaceStreamTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding(24)
            } else {
                List {
                    if !favorites.isEmpty {
                        Section("Favorites") {
                            ForEach(favorites, content: row)
                        }
                    }
                    if !recent.isEmpty {
                        Section(favorites.isEmpty ? "Recent Links" : "Others") {
                            ForEach(recent, content: row)
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }

            Divider().overlay(MaceStreamTheme.border)
            HStack {
                Image(systemName: "lock.shield")
                    .foregroundStyle(MaceStreamTheme.secondaryText)
                Text("Local and private")
                    .font(.caption)
                    .foregroundStyle(MaceStreamTheme.secondaryText)
                Spacer()
                if !history.items.isEmpty {
                    Button(role: .destructive) {
                        showsClearConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(MaceStreamTheme.secondaryText)
                    .help("Clear all history")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 42)
        }
        .background(MaceStreamTheme.panel)
        .confirmationDialog(
            "Clear all link history?",
            isPresented: $showsClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) { history.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Favorites and renamed links will also be deleted. This action cannot be undone.")
        }
    }

    private func row(_ item: HistoryItem) -> some View {
        Button {
            onPlay(item)
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(playback.currentLink == item.link ? MaceStreamTheme.accent.opacity(0.16) : Color.white.opacity(0.045))
                    Image(systemName: playback.currentLink == item.link ? "play.fill" : "antenna.radiowaves.left.and.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(playback.currentLink == item.link ? MaceStreamTheme.accent : MaceStreamTheme.secondaryText)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.displayTitle)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(MaceStreamTheme.primaryText)
                        .lineLimit(1)
                    Text(item.link.shortID)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(MaceStreamTheme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 2)
                if item.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(MaceStreamTheme.accent)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 9)
                .fill(playback.currentLink == item.link ? MaceStreamTheme.accent.opacity(0.07) : Color.clear)
                .padding(.vertical, 1)
        )
        .contextMenu {
            Button { onPlay(item) } label: { Label("Play", systemImage: "play") }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.link.url.absoluteString, forType: .string)
            } label: { Label("Copy Link", systemImage: "doc.on.doc") }
            Divider()
            Button { history.toggleFavorite(item) } label: {
                Label(item.isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: item.isFavorite ? "star.slash" : "star")
            }
            Button { rename(item) } label: { Label("Rename", systemImage: "pencil") }
            Divider()
            Button(role: .destructive) { history.remove(item) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .help(item.link.url.absoluteString)
    }

    private func rename(_ item: HistoryItem) {
        let alert = NSAlert()
        alert.messageText = "Rename link"
        alert.informativeText = "Leave blank to show the content ID."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = item.customTitle ?? ""
        field.placeholderString = "Stream name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        history.rename(item, to: field.stringValue)
    }
}
