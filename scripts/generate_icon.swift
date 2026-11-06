import AppKit

let size: CGFloat = 1024
let outputURL = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png")
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size),
    pixelsHigh: Int(size),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fatalError("Bitmap could not be created")
}
bitmap.size = NSSize(width: size, height: size)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

let iconRect = NSRect(x: 42, y: 42, width: 940, height: 940)
let shape = NSBezierPath(roundedRect: iconRect, xRadius: 218, yRadius: 218)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.075, green: 0.18, blue: 0.20, alpha: 1),
    NSColor(calibratedRed: 0.025, green: 0.045, blue: 0.07, alpha: 1)
])!
gradient.draw(in: shape, angle: -55)

let innerBorder = NSBezierPath(roundedRect: iconRect.insetBy(dx: 3, dy: 3), xRadius: 215, yRadius: 215)
NSColor(calibratedWhite: 1, alpha: 0.11).setStroke()
innerBorder.lineWidth = 5
innerBorder.stroke()

let mint = NSColor(calibratedRed: 0.404, green: 0.910, blue: 0.765, alpha: 1)
let center = NSPoint(x: 485, y: 512)
mint.withAlphaComponent(0.18).setStroke()
for radius in [CGFloat(245), CGFloat(335)] {
    for angles in [(CGFloat(122), CGFloat(238)), (CGFloat(-58), CGFloat(58))] {
        let wave = NSBezierPath()
        wave.appendArc(withCenter: center, radius: radius, startAngle: angles.0, endAngle: angles.1)
        wave.lineWidth = 38
        wave.lineCapStyle = .round
        wave.stroke()
    }
}

mint.withAlphaComponent(0.36).setFill()
NSBezierPath(ovalIn: NSRect(x: 155, y: 482, width: 60, height: 60)).fill()

let play = NSBezierPath()
play.move(to: NSPoint(x: 430, y: 342))
play.line(to: NSPoint(x: 690, y: 512))
play.line(to: NSPoint(x: 430, y: 682))
play.close()
mint.setFill()
play.fill()

NSGraphicsContext.restoreGraphicsState()
guard let data = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("PNG encoding failed")
}
try data.write(to: outputURL)
