import AppKit
import Testing
@testable import Screenboop

@Suite("Image geometry and pixel privacy")
@MainActor
struct ImagingTests {
    @Test("Rendering preserves every original top-left pixel")
    func renderingPreservesOrientation() throws {
        let original = try fixture(width: 37, height: 29) { texture(x: $0, y: $1) }
        let output = try ImageRenderer.render(ImageDocument(image: original))
        try expectPixels(output, width: 37, height: 29) { texture(x: $0, y: $1) }
    }

    @Test("Crop selects top-left physical rows, rounding outward and clipping to the image")
    func cropPreservesOrientation() throws {
        let original = try fixture(width: 37, height: 29) { texture(x: $0, y: $1) }
        let output = try ImageRenderer.crop(original, rect: CGRect(x: -1.2, y: 3.2, width: 16.4, height: 9.1))
        try expectPixels(output, width: 16, height: 10) { texture(x: $0, y: $1 + 3) }
    }

    @Test("Resize keeps asymmetric color quadrants upright")
    func resizePreservesOrientation() throws {
        let original = try fixture(width: 32, height: 24) { x, y in
            if y < 12 { return x < 16 ? .red : .green }
            return x < 16 ? .blue : .yellow
        }
        let output = try ImageRenderer.resize(original, width: 64, height: 48)
        let raster = try Raster(output)
        #expect(raster.width == 64)
        #expect(raster.height == 48)
        #expect(raster[8, 6] == .red)
        #expect(raster[56, 6] == .green)
        #expect(raster[8, 42] == .blue)
        #expect(raster[56, 42] == .yellow)
    }

    @Test("Composed images retain their own top-left origin and white gaps", arguments: [true, false])
    func compositionPreservesOrientation(vertically: Bool) throws {
        let first = try fixture(width: 13, height: 11) { texture(x: $0, y: $1, seed: 1) }
        let second = try fixture(width: 9, height: 7) { texture(x: $0, y: $1, seed: 2) }
        let output = try ImageRenderer.combine([first, second], vertically: vertically)
        let width = vertically ? 13 : 42
        let height = vertically ? 38 : 11
        try expectPixels(output, width: width, height: height) { x, y in
            if x < 13 && y < 11 { return texture(x: x, y: y, seed: 1) }
            let secondX = vertically ? x : x - 33
            let secondY = vertically ? y - 31 : y
            if secondX >= 0 && secondX < 9 && secondY >= 0 && secondY < 7 {
                return texture(x: secondX, y: secondY, seed: 2)
            }
            return .white
        }
    }

    @Test("Pixel sampling uses the same top-left coordinates as the editor")
    func pixelSamplingPreservesOrientation() throws {
        let original = try fixture(width: 7, height: 9) { texture(x: $0, y: $1) }
        for (x, y) in [(0, 0), (6, 0), (0, 8), (6, 8), (2, 3)] {
            let color = try #require(ImageRenderer.pixelColor(original, at: CGPoint(x: CGFloat(x) + 0.4, y: CGFloat(y) + 0.7))?.usingColorSpace(.sRGB))
            let expected = texture(x: x, y: y)
            #expect(Int((color.redComponent * 255).rounded()) == Int(expected.r))
            #expect(Int((color.greenComponent * 255).rounded()) == Int(expected.g))
            #expect(Int((color.blueComponent * 255).rounded()) == Int(expected.b))
            #expect(color.alphaComponent == 1)
        }
    }

    @Test("A translucent chosen redaction color is opaque even in a magnifier outside the mask", arguments: [true, false])
    func magnifierCannotRevealRedactedSource(maskFirst: Bool) throws {
        let original = try fixture(width: 200, height: 200) { x, y in
            (82..<94).contains(x) && (88..<112).contains(y) ? .red : .green
        }
        let mask = Markup(tool: .redact, start: CGPoint(x: 82, y: 88), end: CGPoint(x: 94, y: 112),
                          color: NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 0.12))
        let lens = Markup(tool: .magnifier, start: CGPoint(x: 50, y: 50), end: CGPoint(x: 150, y: 150),
                          color: .black, lineWidth: 2)
        var document = ImageDocument(image: original)
        document.annotations = maskFirst ? [mask, lens] : [lens, mask]
        let output = try Raster(ImageRenderer.render(document))
        #expect(output[85, 100] == .blue)
        // The lens center is outside the mask. At 2x, this unmasked output pixel
        // samples the sensitive source near (85, 100), not its original green.
        #expect(output[70, 100] == .blue)
        #expect(output[170, 100] == .green)
        #expect(try Raster(original)[85, 100] == .red)
    }

    @Test("Pixelation cannot paint over any redaction pixel regardless of annotation order", arguments: [true, false])
    func pixelationCannotOverwriteMask(maskFirst: Bool) throws {
        let original = try fixture(width: 160, height: 160) { texture(x: $0, y: $1) }
        let mask = Markup(tool: .redact, start: CGPoint(x: 30, y: 30), end: CGPoint(x: 110, y: 110),
                          color: NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 0.08))
        let pixelation = Markup(tool: .blur, start: .zero, end: CGPoint(x: 160, y: 160), lineWidth: 16)
        var document = ImageDocument(image: original)
        document.annotations = maskFirst ? [mask, pixelation] : [pixelation, mask]
        let output = try Raster(ImageRenderer.render(document))
        let maskPixels = (30..<110).flatMap { y in (30..<110).map { x in output[x, y] } }
        #expect(maskPixels.allSatisfy { $0 == .blue })
    }

    @Test("Crop undo and redo restore pixels and editable annotations without touching user history")
    func cropUndoRedoRestoresEditableAnnotations() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenboopTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(historyDirectory: directory)
        let original = try fixture(width: 80, height: 60) { texture(x: $0, y: $1) }
        store.load(original, title: "Isolated crop fixture")
        let pen = Markup(tool: .pen, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 30, y: 10),
                         points: [CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 16), CGPoint(x: 30, y: 10)],
                         color: .red, lineWidth: 4)
        let mask = Markup(tool: .redact, start: CGPoint(x: 32, y: 18), end: CGPoint(x: 40, y: 26), color: .blue)
        store.commit(pen)
        store.commit(mask)
        let beforeCrop = try Raster(store.outputImage())
        store.selectionRect = CGRect(x: 8, y: 6, width: 40, height: 32)
        store.cropSelection()
        let cropped = try #require(store.document)
        #expect(cropped.annotations.isEmpty)
        try expectPixels(cropped.image, width: 40, height: 32) { beforeCrop[$0 + 8, $1 + 6] }
        #expect(store.canUndo)

        store.undo()
        let restored = try #require(store.document)
        try expectPixels(restored.image, width: 80, height: 60) { texture(x: $0, y: $1) }
        #expect(restored.annotations.map(\.id) == [pen.id, mask.id])
        let restoredPen = try #require(restored.annotations.first)
        #expect(restoredPen.tool == .pen)
        #expect(restoredPen.points == pen.points)
        #expect(restoredPen.start == pen.start)
        #expect(restoredPen.end == pen.end)
        #expect(restoredPen.lineWidth == pen.lineWidth)
        #expect(restoredPen.color.isEqual(pen.color))
        #expect(try Raster(store.outputImage()).bytes == beforeCrop.bytes)
        #expect(store.canRedo)

        store.redo()
        let redone = try #require(store.document)
        #expect(redone.annotations.isEmpty)
        try expectPixels(redone.image, width: 40, height: 32) { beforeCrop[$0 + 8, $1 + 6] }
        store.undo()
        var moved = try #require(store.document?.annotations.first)
        moved.translate(by: CGPoint(x: 7, y: 5))
        store.replaceAnnotation(moved)
        let edited = try #require(store.document?.annotations.first)
        #expect(edited.id == pen.id)
        #expect(edited.start == CGPoint(x: 17, y: 15))
        #expect(edited.points == pen.points.map { CGPoint(x: $0.x + 7, y: $0.y + 5) })
        #expect(try Raster(store.outputImage()).bytes != beforeCrop.bytes)
        #expect(store.history.isEmpty)
        #expect(store.errorMessage == nil)
    }
}

@Suite("Scrolling image alignment")
struct ScrollStitchingTests {
    @Test("Overlapping frames produce exact source rows and ignore stationary duplicates")
    func overlappingRowsAndDuplicates() throws {
        let first = try fixture(width: 96, height: 300) { texture(x: $0, y: $1) }
        let second = try fixture(width: 96, height: 300) { texture(x: $0, y: $1 + 140) }
        let secondDuplicate = try fixture(width: 96, height: 300) { texture(x: $0, y: $1 + 140) }
        let third = try fixture(width: 96, height: 300) { texture(x: $0, y: $1 + 280) }
        let output = try ScrollStitcher.stitch([first, second, secondDuplicate, third, third])
        try expectPixels(output, width: 96, height: 580) { texture(x: $0, y: $1) }
    }

    @Test("An entirely stationary sequence remains exactly one frame")
    func stationaryFramesAreNotAppended() throws {
        let first = try fixture(width: 96, height: 240) { texture(x: $0, y: $1) }
        let duplicate = try fixture(width: 96, height: 240) { texture(x: $0, y: $1) }
        let output = try ScrollStitcher.stitch([first, duplicate, first])
        try expectPixels(output, width: 96, height: 240) { texture(x: $0, y: $1) }
    }

    @Test("Fixed header and footer occur once around all moving content")
    func fixedHeaderAndFooter() throws {
        let frames = try [0, 100, 200].map { offset in
            try framedFixture(offset: offset)
        }
        let output = try ScrollStitcher.stitch(frames)
        try expectPixels(output, width: 96, height: 500) { x, y in
            if y < 18 { return texture(x: x, y: y, seed: 101) }
            if y >= 478 { return texture(x: x, y: y - 478, seed: 202) }
            return texture(x: x, y: y - 18)
        }
    }

    @Test("A header that changes after alignment is rejected instead of silently spliced")
    func changingFixedHeaderIsRejected() throws {
        let first = try framedFixture(offset: 0)
        let second = try framedFixture(offset: 100)
        let third = try framedFixture(offset: 200, headerSeed: 303)
        #expect(throws: ScreenboopError.self) {
            try ScrollStitcher.stitch([first, second, third])
        }
    }

    @Test("Unrelated frames are rejected rather than concatenated")
    func unmatchedFramesAreRejected() throws {
        let first = try fixture(width: 96, height: 300) { texture(x: $0, y: $1, seed: 1) }
        let second = try fixture(width: 96, height: 300) { texture(x: $0, y: $1, seed: 2) }
        #expect(throws: ScreenboopError.self) {
            try ScrollStitcher.stitch([first, second])
        }
    }

    @Test("Repeated rows with multiple equally good overlaps are rejected")
    func ambiguousFramesAreRejected() throws {
        let first = try fixture(width: 96, height: 300) { texture(x: $0, y: $1 % 20) }
        let second = try fixture(width: 96, height: 300) { texture(x: $0, y: ($1 + 7) % 20) }
        #expect(throws: ScreenboopError.self) {
            try ScrollStitcher.stitch([first, second])
        }
    }

    @Test("A narrow moving column is not silently mistaken for a stationary frame")
    func narrowMovingContentIsNotDiscarded() throws {
        let first = try fixture(width: 512, height: 300) { x, y in
            x == 256 ? texture(x: x, y: y) : .white
        }
        let second = try fixture(width: 512, height: 300) { x, y in
            x == 256 ? texture(x: x, y: y + 100) : .white
        }
        // This selection has too little distinctive content to align reliably.
        // Rejecting it is safe; returning the first frame would lose real movement.
        #expect(throws: ScreenboopError.self) {
            try ScrollStitcher.stitch([first, second])
        }
    }
}

private struct Pixel: Equatable {
    let r: UInt8
    let g: UInt8
    let b: UInt8
    let a: UInt8

    init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    static let red = Pixel(255, 0, 0)
    static let green = Pixel(0, 255, 0)
    static let blue = Pixel(0, 0, 255)
    static let yellow = Pixel(255, 255, 0)
    static let white = Pixel(255, 255, 255)
}

// Original raw RGBA fixtures: row zero is the top row, with no drawing transform
// shared with the production renderer and no external assets or color profiles.
private func fixture(width: Int, height: Int, pixel: (Int, Int) -> Pixel) throws -> CGImage {
    var bytes = [UInt8]()
    bytes.reserveCapacity(width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let value = pixel(x, y)
            bytes.append(contentsOf: [value.r, value.g, value.b, value.a])
        }
    }
    let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: width * 4, space: space,
                               bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
}

private struct Raster {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(_ image: CGImage) throws {
        width = image.width
        height = image.height
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                            bytesPerRow: width * 4, space: space,
                                            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let data = try #require(context.data)
        bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
    }

    subscript(_ x: Int, _ y: Int) -> Pixel {
        let offset = (y * width + x) * 4
        return Pixel(bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
    }
}

private func expectPixels(_ image: CGImage, width: Int, height: Int, pixel: (Int, Int) -> Pixel,
                          sourceLocation: SourceLocation = #_sourceLocation) throws {
    let raster = try Raster(image)
    #expect(raster.width == width, sourceLocation: sourceLocation)
    #expect(raster.height == height, sourceLocation: sourceLocation)
    guard raster.width == width && raster.height == height else { return }
    // One assertion per row produces useful failure locations without thousands
    // of separate Testing events, while still checking every RGBA component.
    for y in 0..<height {
        let actual = (0..<width).map { raster[$0, y] }
        let expected = (0..<width).map { pixel($0, y) }
        #expect(actual == expected, "Pixel row \(y) differs", sourceLocation: sourceLocation)
    }
}

private func texture(x: Int, y: Int, seed: UInt64 = 0) -> Pixel {
    var value = UInt64(x) &* 0x9E3779B185EBCA87
    value ^= UInt64(y) &* 0xC2B2AE3D27D4EB4F
    value ^= seed &* 0x165667B19E3779F9
    value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
    value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
    value ^= value >> 31
    return Pixel(UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value >> 16))
}

private func framedFixture(offset: Int, headerSeed: UInt64 = 101) throws -> CGImage {
    try fixture(width: 96, height: 300) { x, y in
        if y < 18 { return texture(x: x, y: y, seed: headerSeed) }
        if y >= 278 { return texture(x: x, y: y - 278, seed: 202) }
        return texture(x: x, y: y - 18 + offset)
    }
}
