import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// Document and annotation coordinates are physical pixels with a top-left origin.
/// Pixelation is a visual effect, not secure redaction. Use Redact to hide sensitive pixels.
@MainActor
enum ImageRenderer {
    private static let maximumDimension = 32_768
    private static let maximumPixels = 100_000_000
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue

    static func render(_ document: ImageDocument, includeBackdrop: Bool = true) throws -> CGImage {
        try validateSize(width: document.image.width, height: document.image.height)
        for markup in document.annotations { try validate(markup) }
        let backdrop = document.backdrop
        let hasBackdrop = includeBackdrop && backdrop.style != .none
        var padding = 0
        if hasBackdrop {
            guard backdrop.padding.isFinite, backdrop.padding >= 0,
                  backdrop.padding <= CGFloat(maximumDimension),
                  backdrop.cornerRadius.isFinite, backdrop.cornerRadius >= 0 else {
                throw ScreenboopError.message("Backdrop padding and corner radius must be finite, nonnegative pixel values.")
            }
            padding = Int(ceil(backdrop.padding))
            try validateSize(width: document.image.width + padding * 2, height: document.image.height + padding * 2)
        }

        let source = try effectSource(document)
        let context = try makeContext(width: document.image.width, height: document.image.height)
        useTopLeftCoordinates(context, height: document.image.height)
        let imageBounds = CGRect(x: 0, y: 0, width: document.image.width, height: document.image.height)
        context.clip(to: imageBounds)
        drawUpright(source, in: imageBounds, context: context)
        for markup in document.annotations where markup.tool != .redact {
            if markup.tool == .blur {
                try drawPixelation(markup, over: source, in: context)
            } else {
                drawMarkup(markup, over: source, in: context)
            }
        }
        // Privacy masks take precedence over annotation order and every visual effect.
        for markup in document.annotations where markup.tool == .redact {
            drawMarkup(markup, over: source, in: context)
        }
        guard let annotatedImage = context.makeImage() else {
            throw ScreenboopError.message("Could not create the annotated image from its pixel buffer.")
        }
        guard hasBackdrop else { return annotatedImage }

        let width = document.image.width + padding * 2
        let height = document.image.height + padding * 2
        let output = try makeContext(width: width, height: height)
        useTopLeftCoordinates(output, height: height)
        try drawBackdrop(backdrop.style, width: width, height: height, context: output)
        let frame = CGRect(x: padding, y: padding, width: document.image.width, height: document.image.height)
        let radius = min(backdrop.cornerRadius, min(frame.width, frame.height) / 2)
        let path = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)
        output.saveGState()
        if backdrop.shadow && padding > 0 {
            output.setShadow(offset: .zero, blur: min(30, CGFloat(padding) / 2), color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.45))
        }
        // A consistent white card also supplies the silhouette for the optional shadow.
        output.addPath(path)
        output.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        output.fillPath()
        output.restoreGState()
        output.saveGState()
        output.addPath(path)
        output.clip()
        drawUpright(annotatedImage, in: frame, context: output)
        output.restoreGState()
        guard let image = output.makeImage() else {
            throw ScreenboopError.message("Could not create the image with its backdrop.")
        }
        return image
    }

    /// The only image that magnification and pixelation may sample for this document.
    /// Redactions are baked into its pixels before any effects run, including lenses
    /// located outside a mask whose source footprint intersects that mask.
    static func effectSource(_ document: ImageDocument) throws -> CGImage {
        try validateSize(width: document.image.width, height: document.image.height)
        guard document.annotations.contains(where: { $0.tool == .redact }) else {
            return document.image
        }
        for markup in document.annotations where markup.tool == .redact {
            try validate(markup)
        }
        let context = try makeContext(width: document.image.width, height: document.image.height)
        useTopLeftCoordinates(context, height: document.image.height)
        let bounds = CGRect(x: 0, y: 0, width: document.image.width, height: document.image.height)
        context.clip(to: bounds)
        drawUpright(document.image, in: bounds, context: context)
        for markup in document.annotations where markup.tool == .redact {
            drawMarkup(markup, over: document.image, in: context)
        }
        guard let source = context.makeImage() else {
            throw ScreenboopError.message("Could not create the privacy-masked image used by visual effects.")
        }
        return source
    }

    /// The caller supplies a top-left context; this function preserves all of its drawing state.
    /// For document previews, pass effectSource(document) as image and draw redactions last.
    static func drawMarkup(_ markup: Markup, over image: CGImage, in context: CGContext) {
        guard geometryIsValid(markup) else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(1)
        context.setBlendMode(.normal)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let color = markup.color.usingColorSpace(.sRGB) ?? .black
        let width = markup.lineWidth
        context.setStrokeColor(color.cgColor)
        context.setFillColor(color.cgColor)
        context.setLineWidth(width)
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.clip(to: bounds)

        switch markup.tool {
        case .select, .crop:
            break
        case .line:
            drawLine(from: markup.start, to: markup.end, context: context)
        case .arrow:
            let dx = markup.end.x - markup.start.x
            let dy = markup.end.y - markup.start.y
            let length = hypot(dx, dy)
            guard length > 0 else {
                context.fillEllipse(in: CGRect(x: markup.start.x - width / 2, y: markup.start.y - width / 2, width: width, height: width))
                return
            }
            let headLength = min(length * 0.45, max(12, width * 3))
            let ux = dx / length, uy = dy / length
            let base = CGPoint(x: markup.end.x - ux * headLength, y: markup.end.y - uy * headLength)
            drawLine(from: markup.start, to: base, context: context)
            context.move(to: markup.end)
            context.addLine(to: CGPoint(x: base.x - uy * headLength * 0.45, y: base.y + ux * headLength * 0.45))
            context.addLine(to: CGPoint(x: base.x + uy * headLength * 0.45, y: base.y - ux * headLength * 0.45))
            context.closePath()
            context.fillPath()
        case .rectangle:
            context.stroke(markup.rect)
        case .ellipse:
            context.strokeEllipse(in: markup.rect)
        case .pen:
            drawStroke(markup, width: width, context: context)
        case .highlighter:
            context.setAlpha(0.28)
            if !markup.points.isEmpty {
                drawStroke(markup, width: max(12, width * 3), context: context)
            } else if markup.rect.width > 0 && markup.rect.height > 0 {
                context.fill(markup.rect)
            } else {
                context.setLineWidth(max(12, width * 3))
                drawLine(from: markup.start, to: markup.end, context: context)
            }
        case .text:
            drawText(markup.text, at: markup.start, size: max(16, width * 4), color: color.cgColor, context: context)
        case .number:
            drawNumber(markup.text, at: markup.start, size: max(16, width * 4), color: color.withAlphaComponent(1).cgColor, context: context)
        case .blur:
            // The preview API cannot report errors; exports use the throwing implementation.
            try? drawPixelation(markup, over: image, in: context)
        case .redact:
            // Alpha and blend mode are forced: a translucent chosen color must never leak pixels.
            context.setAlpha(1)
            context.setBlendMode(.copy)
            context.setShouldAntialias(false)
            context.setFillColor(color.withAlphaComponent(1).cgColor)
            context.fill(markup.rect.integral.intersection(bounds))
        case .spotlight:
            let region = markup.rect.intersection(bounds)
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.65))
            context.addRect(bounds)
            if !region.isNull && !region.isEmpty { context.addRect(region) }
            context.drawPath(using: .eoFill)
        case .ruler:
            drawLine(from: markup.start, to: markup.end, context: context)
            let dx = markup.end.x - markup.start.x, dy = markup.end.y - markup.start.y
            let length = hypot(dx, dy)
            if length > 0 {
                let tick = max(5, width * 1.5)
                let tx = -dy / length * tick, ty = dx / length * tick
                drawLine(from: CGPoint(x: markup.start.x - tx, y: markup.start.y - ty), to: CGPoint(x: markup.start.x + tx, y: markup.start.y + ty), context: context)
                drawLine(from: CGPoint(x: markup.end.x - tx, y: markup.end.y - ty), to: CGPoint(x: markup.end.x + tx, y: markup.end.y + ty), context: context)
            }
            let label = String(format: "%.1f px", Double(length))
            let fontSize = max(14, width * 3)
            let line = makeTextLine(label, size: fontSize, color: color.cgColor)
            let labelWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let origin = CGPoint(x: (markup.start.x + markup.end.x - labelWidth) / 2, y: (markup.start.y + markup.end.y) / 2 - fontSize - 8)
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92))
            context.fill(CGRect(x: origin.x - 4, y: origin.y - 2, width: labelWidth + 8, height: fontSize * 1.25 + 4))
            drawTextLine(line, at: origin, context: context)
        case .magnifier:
            let rect = markup.rect
            let diameter = min(rect.width, rect.height)
            let lens: CGRect
            if diameter >= 2 {
                lens = CGRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2, width: diameter, height: diameter)
            } else {
                let fallbackDiameter = max(80, width * 20)
                lens = CGRect(x: markup.end.x - fallbackDiameter / 2, y: markup.end.y - fallbackDiameter / 2, width: fallbackDiameter, height: fallbackDiameter)
            }
            context.saveGState()
            context.addEllipse(in: lens)
            context.clip()
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(lens)
            let zoomedBounds = CGRect(x: lens.midX - lens.midX * 2, y: lens.midY - lens.midY * 2, width: bounds.width * 2, height: bounds.height * 2)
            context.interpolationQuality = .high
            drawUpright(image, in: zoomedBounds, context: context)
            context.restoreGState()
            context.strokeEllipse(in: lens)
        }
    }

    static func crop(_ image: CGImage, rect: CGRect) throws -> CGImage {
        try validateSize(width: image.width, height: image.height)
        guard finite(rect), rect.width != 0, rect.height != 0 else {
            throw ScreenboopError.message("Crop bounds must be finite and have a nonzero width and height.")
        }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let intersection = rect.standardized.intersection(bounds)
        guard !intersection.isNull, !intersection.isEmpty else {
            throw ScreenboopError.message("The crop selection does not intersect the image.")
        }
        // Include every selected physical pixel; constrain the rounded bounds to the image.
        let pixelBounds = intersection.integral.intersection(bounds)
        guard let result = image.cropping(to: pixelBounds) else {
            throw ScreenboopError.message("Could not crop the selected image pixels.")
        }
        return result
    }

    static func resize(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        try validateSize(width: image.width, height: image.height)
        let context = try makeContext(width: width, height: height)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else {
            throw ScreenboopError.message("Could not create the resized image.")
        }
        return result
    }

    static func combine(_ images: [CGImage], vertically: Bool) throws -> CGImage {
        guard !images.isEmpty else {
            throw ScreenboopError.message("Select at least one image to combine.")
        }
        var along = 0
        var across = 0
        for (index, image) in images.enumerated() {
            try validateSize(width: image.width, height: image.height)
            let dimension = vertically ? image.height : image.width
            let increment = dimension + (index == 0 ? 0 : 20)
            guard along <= maximumDimension - increment else {
                throw ScreenboopError.message("Combined images, including their 20-pixel gaps, exceed the 32,768-pixel dimension limit.")
            }
            along += increment
            across = max(across, vertically ? image.width : image.height)
        }
        let width = vertically ? across : along
        let height = vertically ? along : across
        let context = try makeContext(width: width, height: height)
        useTopLeftCoordinates(context, height: height)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var position = 0
        for image in images {
            let frame = CGRect(x: vertically ? 0 : position, y: vertically ? position : 0, width: image.width, height: image.height)
            drawUpright(image, in: frame, context: context)
            position += (vertically ? image.height : image.width) + 20
        }
        guard let result = context.makeImage() else {
            throw ScreenboopError.message("Could not create the combined image.")
        }
        return result
    }

    static func pngData(_ image: CGImage) throws -> Data {
        try validateSize(width: image.width, height: image.height)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ScreenboopError.message("Could not create a PNG encoder.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ScreenboopError.message("PNG encoding failed. The image could not be exported.")
        }
        return data as Data
    }

    /// Returns unpremultiplied, normalized sRGB components, preserving the sampled alpha.
    static func pixelColor(_ image: CGImage, at point: CGPoint) -> NSColor? {
        guard point.x.isFinite, point.y.isFinite, point.x >= 0, point.y >= 0,
              point.x < CGFloat(image.width), point.y < CGFloat(image.height),
              let pixel = image.cropping(to: CGRect(x: floor(point.x), y: floor(point.y), width: 1, height: 1)) else { return nil }
        var rgba: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)
        let sampled = withUnsafeMutableBytes(of: &rgba) { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: colorSpace, bitmapInfo: bitmapInfo) else { return false }
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard sampled else { return nil }
        let alpha = CGFloat(rgba.3) / 255
        let divisor = CGFloat(max(1, rgba.3))
        return NSColor(srgbRed: min(1, CGFloat(rgba.0) / divisor), green: min(1, CGFloat(rgba.1) / divisor), blue: min(1, CGFloat(rgba.2) / divisor), alpha: alpha)
    }

    private static func validateSize(width: Int, height: Int) throws {
        guard width > 0, height > 0 else {
            throw ScreenboopError.message("Image dimensions must be positive pixel counts.")
        }
        guard width <= maximumDimension, height <= maximumDimension else {
            throw ScreenboopError.message("Image dimensions cannot exceed 32,768 pixels on either axis.")
        }
        guard width <= maximumPixels / height else {
            throw ScreenboopError.message("Images cannot exceed 100 million output pixels.")
        }
    }

    private static func makeContext(width: Int, height: Int) throws -> CGContext {
        try validateSize(width: width, height: height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace, bitmapInfo: bitmapInfo) else {
            throw ScreenboopError.message("Could not allocate a \(width) × \(height) sRGB image buffer. Try a smaller image.")
        }
        return context
    }

    private static func useTopLeftCoordinates(_ context: CGContext, height: Int) {
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
    }

    private static func drawUpright(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    private static func drawPixelation(_ markup: Markup, over image: CGImage, in context: CGContext) throws {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let selection = markup.rect.intersection(bounds)
        guard !selection.isNull, !selection.isEmpty else { return }
        let region = selection.integral.intersection(bounds)
        guard let cropped = image.cropping(to: region) else {
            throw ScreenboopError.message("Could not read the pixels selected for pixelation.")
        }
        // Average into a small image, then enlarge with nearest-neighbor interpolation.
        // This visual effect is reversible in principle and is not secure redaction.
        let block = max(8, markup.lineWidth * 2)
        let smallWidth = max(1, Int(ceil(region.width / block)))
        let smallHeight = max(1, Int(ceil(region.height / block)))
        let small = try makeContext(width: smallWidth, height: smallHeight)
        small.interpolationQuality = .high
        small.draw(cropped, in: CGRect(x: 0, y: 0, width: smallWidth, height: smallHeight))
        guard let pixelated = small.makeImage() else {
            throw ScreenboopError.message("Could not create the pixelated region.")
        }
        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(1)
        context.setBlendMode(.normal)
        context.interpolationQuality = .none
        context.clip(to: selection)
        drawUpright(pixelated, in: region, context: context)
    }

    private static func finite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite && rect.maxX.isFinite && rect.maxY.isFinite
    }

    private static func geometryIsValid(_ markup: Markup) -> Bool {
        let limit = CGFloat(maximumDimension) * 4
        func valid(_ point: CGPoint) -> Bool {
            point.x.isFinite && point.y.isFinite && abs(point.x) <= limit && abs(point.y) <= limit
        }
        return valid(markup.start) && valid(markup.end) && markup.points.allSatisfy(valid)
            && markup.lineWidth.isFinite && markup.lineWidth > 0 && markup.lineWidth <= CGFloat(maximumDimension)
            && markup.text.utf16.count <= 100_000 && markup.points.count <= 1_000_000
    }

    private static func validate(_ markup: Markup) throws {
        guard geometryIsValid(markup) else {
            throw ScreenboopError.message("An annotation has invalid or unbounded geometry, line width, text, or pen points.")
        }
        guard markup.color.usingColorSpace(.sRGB) != nil else {
            throw ScreenboopError.message("Annotation colors must be convertible to sRGB; pattern colors are not supported.")
        }
    }

    private static func drawLine(from start: CGPoint, to end: CGPoint, context: CGContext) {
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
    }

    private static func drawStroke(_ markup: Markup, width: CGFloat, context: CGContext) {
        context.setLineWidth(width)
        if markup.points.count == 1, let point = markup.points.first {
            context.fillEllipse(in: CGRect(x: point.x - width / 2, y: point.y - width / 2, width: width, height: width))
        } else if let first = markup.points.first {
            context.move(to: first)
            for point in markup.points.dropFirst() { context.addLine(to: point) }
            context.strokePath()
        } else if markup.start == markup.end {
            context.fillEllipse(in: CGRect(x: markup.start.x - width / 2, y: markup.start.y - width / 2, width: width, height: width))
        } else {
            drawLine(from: markup.start, to: markup.end, context: context)
        }
    }

    private static func makeTextLine(_ text: String, size: CGFloat, color: CGColor) -> CTLine {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes) as CFAttributedString)
    }

    private static func drawTextLine(_ line: CTLine, at point: CGPoint, context: CGContext) {
        var ascent: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, nil, nil)
        context.saveGState()
        context.translateBy(x: point.x, y: point.y + ascent)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func drawText(_ text: String, at point: CGPoint, size: CGFloat, color: CGColor, context: CGContext) {
        var y = point.y
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            let line = makeTextLine(String(text[range]), size: size, color: color)
            drawTextLine(line, at: CGPoint(x: point.x, y: y), context: context)
            y += size * 1.25
        }
    }

    private static func drawNumber(_ text: String, at center: CGPoint, size: CGFloat, color: CGColor, context: CGContext) {
        let line = makeTextLine(text, size: size, color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let diameter = max(32, size * 1.8, textWidth + 16)
        context.setFillColor(color)
        context.fillEllipse(in: CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter))
        drawTextLine(line, at: CGPoint(x: center.x - textWidth / 2, y: center.y - (ascent + descent) / 2), context: context)
    }

    private static func drawBackdrop(_ style: BackdropStyle, width: Int, height: Int, context: CGContext) throws {
        let colors: [CGColor]
        switch style {
        case .none:
            return
        case .aurora:
            colors = [CGColor(srgbRed: 0.40, green: 0.22, blue: 0.86, alpha: 1), CGColor(srgbRed: 0.25, green: 0.48, blue: 0.94, alpha: 1), CGColor(srgbRed: 0.25, green: 0.85, blue: 0.72, alpha: 1)]
        case .midnight:
            colors = [CGColor(srgbRed: 0.05, green: 0.07, blue: 0.15, alpha: 1), CGColor(srgbRed: 0.16, green: 0.21, blue: 0.35, alpha: 1)]
        case .peach:
            colors = [CGColor(srgbRed: 1, green: 0.71, blue: 0.68, alpha: 1), CGColor(srgbRed: 1, green: 0.88, blue: 0.69, alpha: 1)]
        }
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: nil) else {
            throw ScreenboopError.message("Could not create the backdrop gradient.")
        }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
}
