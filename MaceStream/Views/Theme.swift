import SwiftUI

enum MaceStreamTheme {
    static let background = Color(hex: 0x090D12)
    static let panel = Color(hex: 0x111820)
    static let raisedPanel = Color(hex: 0x18222D)
    static let accent = Color(hex: 0x67E8C3)
    static let secondaryAccent = Color(hex: 0x65A9FF)
    static let primaryText = Color(hex: 0xF2F5F7)
    static let secondaryText = Color(hex: 0x91A0AE)
    static let danger = Color(hex: 0xFF7474)
    static let border = Color.white.opacity(0.09)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: 1
        )
    }
}

struct CardBackground: ViewModifier {
    var cornerRadius: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .background(MaceStreamTheme.panel, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(MaceStreamTheme.border, lineWidth: 1)
            }
    }
}

extension View {
    func cardBackground(cornerRadius: CGFloat = 14) -> some View {
        modifier(CardBackground(cornerRadius: cornerRadius))
    }
}
