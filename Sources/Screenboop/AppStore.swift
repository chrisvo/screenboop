import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var document: ImageDocument?
    @Published private(set) var preview: CGImage?
    @Published var tool: EditorTool = .arrow
    @Published var color: NSColor = NSColor(srgbRed: 0.40, green: 0.34, blue: 0.95, alpha: 1)
    @Published var lineWidth: Double = 5
    @Published var zoom: CGFloat = 0.65
    @Published var selectedID: UUID?
    @Published var selectionRect: CGRect?
    @Published var status = "Ready when you are. Everything stays on your Mac."
    @Published var errorMessage: String?
    @Published var isBusy = false
    @Published var history: [HistoryItem] = []
    @Published var showRecognition = false
    @Published var recognizedText = ""
    @Published var showResize = false
    @Published var showAbout = false
    @Published var hoverPosition: CGPoint?
    @Published var hoverHex = "—"
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    var viewport = CGSize(width: 950, height: 680)
    var showWindow: (() -> Void)?
    let captureService = CaptureService()
    private let historyStore: CaptureHistory?
    private var undoStack: [ImageDocument] = []
    private var redoStack: [ImageDocument] = []
    private var pins: [PinWindowController] = []
    private var task: Task<Void, Never>?

    init(historyDirectory: URL? = nil) {
        do {
            let storage = try CaptureHistory(directory: historyDirectory)
            let existing = try storage.items()
            historyStore = storage
            history = existing
        } catch {
            historyStore = nil
            errorMessage = "Capture history is unavailable: \(error.localizedDescription). Editing and export still work."
        }
        captureService.onStatus = { [weak self] message in self?.status = message }
    }

    func report(_ error: Error) {
        errorMessage = error.localizedDescription
        status = error.localizedDescription
    }

    @discardableResult
    func updateDocument(_ value: ImageDocument, remember: Bool = true) -> Bool {
        do {
            let rendered = try ImageRenderer.render(value)
            if remember, let current = document {
                undoStack.append(current)
                if undoStack.count > 30 { undoStack.removeFirst() }
                redoStack.removeAll()
            }
            document = value
            preview = rendered
            canUndo = !undoStack.isEmpty
            canRedo = !redoStack.isEmpty
            return true
        } catch { report(error); return false }
    }

    func load(_ image: CGImage, title: String, recordHistory: Bool = false) {
        let value = ImageDocument(image: image, title: title)
        guard updateDocument(value, remember: false) else { return }
        undoStack.removeAll(); redoStack.removeAll()
        canUndo = false; canRedo = false
        selectionRect = nil; selectedID = nil
        zoomToFit()
        status = "\(title) · \(image.width) × \(image.height) px"
        if recordHistory { saveHistory(image) }
    }

    func importFile(_ url: URL) {
        guard !isBusy else { return }
        isBusy = true
        task = Task {
            defer { isBusy = false }
            do {
                let image = try await Task.detached(priority: .userInitiated) { try ImageFiles.load(url) }.value
                try Task.checkCancellation()
                load(image, title: url.deletingPathExtension().lastPathComponent)
                showWindow?()
            } catch is CancellationError { status = "Open cancelled. Your image is unchanged." }
            catch { report(error) }
        }
    }

    func openImage() {
        let panel = NSOpenPanel()
        panel.title = "Open an image in Screenboop"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { importFile(url) }
    }

    func pasteImage() {
        guard !isBusy else { return }
        let board = NSPasteboard.general
        if let data = board.data(forType: .png),
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            guard image.width <= 32768, image.height <= 32768,
                  Int64(image.width) * Int64(image.height) <= 100_000_000 else {
                report(ScreenboopError.message("Clipboard image exceeds the 100-megapixel limit.")); return
            }
            load(image, title: "Clipboard image")
        } else if let image = NSImage(pasteboard: board),
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            guard cg.width <= 32768, cg.height <= 32768, Int64(cg.width) * Int64(cg.height) <= 100_000_000 else {
                report(ScreenboopError.message("Clipboard image exceeds the 100-megapixel limit.")); return
            }
            load(cg, title: "Clipboard image")
        } else { report(ScreenboopError.message("The clipboard does not contain an image. Copy an image, then try again.")) }
        showWindow?()
    }

    func capture(_ mode: CaptureMode) {
        guard !isBusy else { return }
        isBusy = true
        status = mode.title
        NSApp.hide(nil)
        task = Task {
            defer {
                isBusy = false
                NSApp.unhideWithoutActivation()
                showWindow?()
            }
            do {
                try await Task.sleep(for: .milliseconds(250))
                if let image = try await captureService.capture(mode) {
                    let formatter = DateFormatter(); formatter.dateFormat = "HH.mm.ss"
                    load(image, title: "Capture \(formatter.string(from: Date()))", recordHistory: true)
                } else { status = "Capture cancelled. Your image is unchanged." }
            } catch is CancellationError { status = "Capture cancelled." }
            catch { report(error) }
        }
    }

    func cancelCapture() {
        captureService.cancel()
        task?.cancel()
    }

    func commit(_ markup: Markup) {
        guard var value = document else { return }
        value.annotations.append(markup)
        if updateDocument(value) { selectedID = markup.id; selectionRect = nil }
    }

    func replaceAnnotation(_ markup: Markup) {
        guard var value = document, let index = value.annotations.firstIndex(where: { $0.id == markup.id }) else { return }
        value.annotations[index] = markup
        _ = updateDocument(value)
    }

    func deleteSelection() {
        guard let selectedID, var value = document else { selectionRect = nil; return }
        value.annotations.removeAll { $0.id == selectedID }
        if updateDocument(value) { self.selectedID = nil }
    }

    func undo() {
        guard let previous = undoStack.popLast(), let current = document else { return }
        if updateDocument(previous, remember: false) {
            redoStack.append(current); selectedID = nil; selectionRect = nil
        } else { undoStack.append(previous) }
        canUndo = !undoStack.isEmpty; canRedo = !redoStack.isEmpty
    }

    func redo() {
        guard let next = redoStack.popLast(), let current = document else { return }
        if updateDocument(next, remember: false) {
            undoStack.append(current); selectedID = nil; selectionRect = nil
        } else { redoStack.append(next) }
        canUndo = !undoStack.isEmpty; canRedo = !redoStack.isEmpty
    }

    func cropSelection() {
        guard let rect = selectionRect, var value = document else { return }
        do {
            let flattened = try ImageRenderer.render(value, includeBackdrop: false)
            value.image = try ImageRenderer.crop(flattened, rect: rect)
            value.annotations.removeAll()
            if updateDocument(value) { selectionRect = nil; selectedID = nil; zoomToFit(); status = "Cropped to \(value.image.width) × \(value.image.height) px. Undo restores the original." }
        } catch { report(error) }
    }

    func resize(width: Int, height: Int) {
        guard var value = document else { return }
        do {
            value.image = try ImageRenderer.resize(ImageRenderer.render(value, includeBackdrop: false), width: width, height: height)
            value.annotations.removeAll()
            if updateDocument(value) { selectedID = nil; selectionRect = nil; zoomToFit(); showResize = false }
        } catch { report(error) }
    }

    func changeBackdrop(style: BackdropStyle? = nil, padding: CGFloat? = nil) {
        guard var value = document else { return }
        if let style { value.backdrop.style = style }
        if let padding { value.backdrop.padding = padding }
        if updateDocument(value) { zoomToFit() }
    }

    func combineImages(vertically: Bool) {
        guard let value = document, !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = vertically ? "Stack images below this image" : "Place images beside this image"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        isBusy = true
        task = Task {
            defer { isBusy = false }
            do {
                let base = try ImageRenderer.render(value, includeBackdrop: false)
                let others = try await Task.detached { try urls.map { try ImageFiles.load($0) } }.value
                try Task.checkCancellation()
                let combined = try ImageRenderer.combine([base] + others, vertically: vertically)
                let next = ImageDocument(image: combined, title: "Combined images")
                if updateDocument(next) { selectedID = nil; selectionRect = nil; zoomToFit() }
            } catch is CancellationError { status = "Combine cancelled. Your image is unchanged." }
            catch { report(error) }
        }
    }

    func outputImage() throws -> CGImage {
        guard let value = document else { throw ScreenboopError.message("Capture or open an image first.") }
        return try ImageRenderer.render(value)
    }

    func copyImage() {
        do {
            let image = try outputImage()
            let data = try ImageRenderer.pngData(image)
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setData(data, forType: .png) else { throw ScreenboopError.message("The clipboard could not accept the image.") }
            status = "Copied \(image.width) × \(image.height) PNG to clipboard."
        } catch { report(error) }
    }

    func exportImage(jpeg: Bool = false) {
        guard document != nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = jpeg ? [.jpeg] : [.png]
        panel.nameFieldStringValue = "\(document?.title ?? "Screenboop").\(jpeg ? "jpg" : "png")"
        panel.canCreateDirectories = true
        panel.title = "Export flattened image"
        if let path = UserDefaults.standard.string(forKey: "exportDirectory") { panel.directoryURL = URL(fileURLWithPath: path) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try writeExport(to: url, jpeg: jpeg)
            UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: "exportDirectory")
            status = "Saved \(url.lastPathComponent)."
        } catch { report(error) }
    }

    func writeExport(to url: URL, jpeg: Bool = false) throws {
        let image = try outputImage()
        let data = try jpeg ? ImageFiles.jpegData(image) : ImageRenderer.pngData(image)
        try data.write(to: url, options: .atomic)
    }

    func recognizeText() {
        guard let value = document, !isBusy else { return }
        isBusy = true; status = "Reading text and QR codes on your Mac…"
        task = Task {
            defer { isBusy = false }
            do {
                var image = try ImageRenderer.render(value, includeBackdrop: false)
                if let selectionRect { image = try ImageRenderer.crop(image, rect: selectionRect) }
                let result = try await TextRecognition.recognize(image)
                try Task.checkCancellation()
                recognizedText = result.clipboardText
                showRecognition = true
                status = recognizedText.isEmpty ? "No text or QR code was detected." : "Text recognition complete. No network requests were made."
            } catch is CancellationError { status = "Text recognition cancelled." }
            catch { report(error) }
        }
    }

    func copyRecognizedText() {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(recognizedText, forType: .string) {
            status = "Recognized text copied."; showRecognition = false
        }
    }

    func sampleColor(at point: CGPoint) {
        hoverPosition = point
        guard let image = document?.image,
              let sampled = ImageRenderer.pixelColor(image, at: point)?.usingColorSpace(.sRGB) else { hoverHex = "—"; return }
        hoverHex = String(format: "#%02X%02X%02X", Int((sampled.redComponent * 255).rounded()),
            Int((sampled.greenComponent * 255).rounded()), Int((sampled.blueComponent * 255).rounded()))
    }

    func copyColor() {
        guard hoverHex != "—" else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hoverHex, forType: .string)
        status = "Copied \(hoverHex) from the original image pixel."
    }

    func zoomToFit() {
        guard let preview else { return }
        zoom = max(0.05, min(1, min((viewport.width - 80) / CGFloat(preview.width), (viewport.height - 80) / CGFloat(preview.height))))
    }

    func pin() {
        do {
            pins.removeAll { $0.window?.isVisible != true }
            let controller = PinWindowController(image: try outputImage())
            pins.append(controller)
            controller.showWindow(nil)
            status = "Pinned reference. Drag to move, resize its edges, or use × to close."
        } catch { report(error) }
    }

    func saveHistory(_ image: CGImage) {
        do {
            guard let historyStore else { throw ScreenboopError.message("Capture history is unavailable.") }
            try historyStore.save(image)
            history = try historyStore.items()
        } catch { report(error) }
    }

    func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Delete Screenboop’s saved capture history?"
        alert.informativeText = "This removes images in Screenboop’s private capture folder, including unredacted originals. Exported files elsewhere and the current editor image are unchanged."
        alert.addButton(withTitle: "Delete history")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try historyStore?.clear(); history = try historyStore?.items() ?? []; status = "Capture history cleared." }
        catch { report(error) }
    }

    func revealHistory() {
        if let historyStore { NSWorkspace.shared.open(historyStore.directory) }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }

    func newExample() {
        load(ExampleImage.make(), title: "Example — not a screen capture")
    }
}
