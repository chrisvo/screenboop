import AppKit
import ImageIO
import UniformTypeIdentifiers

// ImageIO owns orientation and pixel decoding at the import boundary.
enum ImageFiles {
    static func load(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 32768, height <= 32768,
              Int64(width) * Int64(height) <= 100_000_000 else {
            throw ScreenboopError.message("This image cannot be decoded, or exceeds the 100-megapixel / 32,768-pixel dimension limit.")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ScreenboopError.message("macOS could not decode \(url.lastPathComponent).")
        }
        return image
    }

    static func thumbnail(_ url: URL, size: Int = 160) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: size
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }

    static func jpegData(_ image: CGImage) throws -> Data {
        // JPEG has no alpha; explicitly composite over white, not implicit black.
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ScreenboopError.message("Not enough memory to export JPEG.")
        }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let flattened = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: flattened).representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else {
            throw ScreenboopError.message("macOS could not encode this JPEG.")
        }
        return data
    }
}

@MainActor
final class CaptureHistory {
    let directory: URL
    init(directory: URL? = nil) throws {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Screenboop/Captures", isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    func items() throws -> [HistoryItem] {
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles])
        return files.filter { $0.pathExtension.lowercased() == "png" }.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.creationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
            return HistoryItem(url: url, date: values.creationDate ?? .distantPast, width: width, height: height)
        }.sorted { $0.date > $1.date }
    }

    @discardableResult
    func save(_ image: CGImage) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = "Screenboop \(formatter.string(from: Date())) \(UUID().uuidString.prefix(6)).png"
        let destination = directory.appendingPathComponent(name)
        try ImageRenderer.pngData(image).write(to: destination, options: .atomic)
        return destination
    }

    func clear() throws {
        // Only files listed from our exact owned captures directory are removed.
        for item in try items() { try FileManager.default.removeItem(at: item.url) }
    }
}
