#if DEBUG
import SwiftUI

struct CaptureArtworkView: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24)) { context in
            let time = context.date.timeIntervalSince1970
            GeometryReader { geometry in
                let width = geometry.size.width
                let height = geometry.size.height
                ZStack {
                    LinearGradient(
                        colors: [
                            Color(hex: 0x07151C),
                            Color(hex: 0x0B3035),
                            Color(hex: 0x101424)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    RadialGradient(
                        colors: [MaceStreamTheme.accent.opacity(0.18), .clear],
                        center: .init(x: 0.68, y: 0.36),
                        startRadius: 10,
                        endRadius: width * 0.48
                    )
                    CaptureGridView(time: time, width: width, height: height)
                        .stroke(MaceStreamTheme.accent.opacity(0.13), lineWidth: 1)
                    VStack(spacing: 18) {
                        HStack(spacing: 9) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                            Text("SAMPLE PREVIEW")
                                .tracking(2.2)
                        }
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(MaceStreamTheme.accent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.black.opacity(0.32), in: Capsule())

                        Text("Your stream. Right here.")
                            .font(.system(size: 30, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.4), radius: 12)
                        Text("Native playback with a deliberately quiet interface.")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .offset(y: height * 0.03)
                }
                .frame(width: width, height: height)
            }
        }
        .background(Color.black)
    }
}

private struct CaptureGridView: Shape {
    var time: Double
    let width: CGFloat
    let height: CGFloat

    var animatableData: Double {
        get { time }
        set { time = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let spacing: CGFloat = 54
        let drift = CGFloat((time * 8).truncatingRemainder(dividingBy: Double(spacing)))
        var x = -height + drift
        while x < width + height {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x + height, y: height))
            x += spacing
        }
        var y = drift
        while y < height {
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: width, y: y))
            y += spacing
        }
        return path
    }
}
#endif
