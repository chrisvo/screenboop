import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let rect = CGRect(x: 62, y: 62, width: 900, height: 900)
        let path = NSBezierPath(roundedRect: rect, xRadius: 204, yRadius: 204)
        NSGradient(starting: NSColor(srgbRed: 0.50, green: 0.40, blue: 1, alpha: 1), ending: NSColor(srgbRed: 0.31, green: 0.23, blue: 0.79, alpha: 1))!.draw(in: path, angle: -65)
        let lines = NSBezierPath()
        lines.lineWidth = 46; lines.lineCapStyle = .round; lines.lineJoinStyle = .round
        for (corner, dx, dy) in [(CGPoint(x: 285,y: 285), CGFloat(1), CGFloat(1)), (CGPoint(x: 739,y: 285), -1, 1), (CGPoint(x: 285,y: 739), 1, -1), (CGPoint(x: 739,y: 739), -1, -1)] {
            lines.move(to: CGPoint(x: corner.x, y: corner.y + dy * 112))
            lines.line(to: corner)
            lines.line(to: CGPoint(x: corner.x + dx * 112, y: corner.y))
        }
        NSColor.white.setStroke(); lines.stroke()
        NSColor(srgbRed: 0.77, green: 0.98, blue: 0.59, alpha: 1).setFill()
        NSBezierPath(ovalIn: CGRect(x: 610, y: 618, width: 126, height: 126)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let filename = "icon_\(size)x\(size)\(suffix).png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(filename))
    }
}
