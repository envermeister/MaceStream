import AppKit
import SwiftUI

struct LinkEntryView: View {
    @Binding var text: String
    @Binding var validationError: String?
    let onPlay: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "link")
                        .foregroundStyle(isFocused ? MaceStreamTheme.accent : MaceStreamTheme.secondaryText)
                    TextField("acestream:// link or 40-character content ID", text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .focused($isFocused)
                        .onSubmit(onPlay)
                        .onChange(of: text) { _ in validationError = nil }

                    if !text.isEmpty {
                        Button {
                            text = ""
                            isFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(MaceStreamTheme.secondaryText)
                        }
                        .buttonStyle(.plain)
                        .help("Clear")
                    }
                }
                .padding(.horizontal, 13)
                .frame(height: 44)
                .background(MaceStreamTheme.panel, in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            validationError != nil ? MaceStreamTheme.danger.opacity(0.75) :
                                isFocused ? MaceStreamTheme.accent.opacity(0.65) : MaceStreamTheme.border,
                            lineWidth: 1
                        )
                }

                Button(action: paste) {
                    Image(systemName: "doc.on.clipboard")
                        .frame(width: 20)
                }
                .buttonStyle(ToolbarActionButtonStyle())
                .help("Paste from Clipboard")

                Button(action: onPlay) {
                    Label("Play", systemImage: "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 8)
                }
                .buttonStyle(PlayButtonStyle())
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }

            if let validationError {
                Label(validationError, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(MaceStreamTheme.danger)
                    .padding(.leading, 4)
            }
        }
    }

    private func paste() {
        guard let value = NSPasteboard.general.string(forType: .string) else {
            NSSound.beep()
            return
        }
        text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        isFocused = true
    }
}

struct PlayButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color(hex: 0x09261F))
            .frame(height: 44)
            .background(
                MaceStreamTheme.accent.opacity(isEnabled ? configuration.isPressed ? 0.72 : 1 : 0.28),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct ToolbarActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(MaceStreamTheme.primaryText)
            .frame(width: 44, height: 44)
            .background(
                MaceStreamTheme.raisedPanel.opacity(configuration.isPressed ? 0.65 : 1),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(MaceStreamTheme.border)
            }
    }
}
