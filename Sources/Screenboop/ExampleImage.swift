import AppKit

// An original, explicitly labeled practice image. Never presented as a capture.
enum ExampleImage {
    static func make() -> CGImage {
        let size = CGSize(width: 1200, height: 760)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 760,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSColor(srgbRed: 0.94, green: 0.94, blue: 0.98, alpha: 1).setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
        let card = CGRect(x: 110, y: 105, width: 980, height: 550)
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.12)
        shadow.shadowBlurRadius = 35; shadow.shadowOffset = CGSize(width: 0, height: -12)
        NSGraphicsContext.saveGraphicsState(); shadow.set()
        NSColor.white.setFill(); NSBezierPath(roundedRect: card, xRadius: 22, yRadius: 22).fill()
        NSGraphicsContext.restoreGraphicsState()
        for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            color.withAlphaComponent(0.8).setFill()
            NSBezierPath(ovalIn: CGRect(x: 136 + i * 22, y: 617, width: 12, height: 12)).fill()
        }
        draw("ACME / DESIGN SYSTEM", at: CGPoint(x: 155, y: 545), font: .systemFont(ofSize: 13, weight: .semibold), color: .secondaryLabelColor)
        draw("A little clarity goes a long way.", at: CGPoint(x: 155, y: 468), font: .systemFont(ofSize: 36, weight: .bold), color: NSColor(srgbRed: 0.12, green: 0.13, blue: 0.22, alpha: 1))
        draw("Make your feedback visual. Point out the details, hide the private bits,", at: CGPoint(x: 155, y: 424), font: .systemFont(ofSize: 19), color: .secondaryLabelColor)
        draw("and share something worth a thousand words.", at: CGPoint(x: 155, y: 393), font: .systemFont(ofSize: 19), color: .secondaryLabelColor)
        let swatches: [NSColor] = [.init(srgbRed: 0.4, green: 0.34, blue: 0.95, alpha: 1), .init(srgbRed: 0.31, green: 0.74, blue: 0.63, alpha: 1), .init(srgbRed: 0.98, green: 0.73, blue: 0.39, alpha: 1)]
        for (i, color) in swatches.enumerated() {
            color.setFill(); NSBezierPath(roundedRect: CGRect(x: 155 + i * 270, y: 215, width: 245, height: 126), xRadius: 14, yRadius: 14).fill()
            draw(["01  Capture", "02  Annotate", "03  Share"][i], at: CGPoint(x: 176 + i * 270, y: 260), font: .systemFont(ofSize: 21, weight: .semibold), color: .white)
        }
        draw("Example content  •  Private note: hello@screenboop.local  •  No account needed", at: CGPoint(x: 155, y: 155), font: .monospacedSystemFont(ofSize: 14, weight: .regular), color: .secondaryLabelColor)
        return bitmap.cgImage!
    }
    private static func draw(_ text: String, at point: CGPoint, font: NSFont, color: NSColor) {
        (text as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
    }
}
