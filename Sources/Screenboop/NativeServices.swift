import AppKit
import Carbon
import Vision

// These requests operate on local image bytes; no text or pixels leave the Mac.
enum TextRecognition {
    static func recognize(_ image: CGImage) async throws -> RecognizedContent {
        try await Task.detached(priority: .userInitiated) {
            let text = VNRecognizeTextRequest()
            text.recognitionLevel = .accurate
            text.usesLanguageCorrection = true
            text.automaticallyDetectsLanguage = true
            let codes = VNDetectBarcodesRequest()
            codes.symbologies = [.qr]
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([text, codes])
            let lines = (text.results ?? []).sorted {
                let dy = $0.boundingBox.midY - $1.boundingBox.midY
                return abs(dy) > 0.015 ? dy > 0 : $0.boundingBox.minX < $1.boundingBox.minX
            }.compactMap { $0.topCandidates(1).first?.string }
            let payloads = (codes.results ?? []).compactMap(\.payloadStringValue)
            return RecognizedContent(text: lines.joined(separator: "\n"), codes: payloads)
        }.value
    }
}

@MainActor
final class GlobalHotKeys {
    private var references: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private let action: (UInt32) -> Void

    init(action: @escaping (UInt32) -> Void) {
        self.action = action
    }

    func register() -> String? {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installation = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr else { return status }
            let owner = Unmanaged<GlobalHotKeys>.fromOpaque(userData).takeUnretainedValue()
            let id = identifier.id
            Task { @MainActor in owner.action(id) }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installation == noErr else { return "Global shortcuts could not be installed (\(installation)). Use the menu bar instead." }
        let keys: [UInt32] = [UInt32(kVK_ANSI_1), UInt32(kVK_ANSI_2), UInt32(kVK_ANSI_3), UInt32(kVK_ANSI_4), UInt32(kVK_ANSI_5)]
        var failures: [String] = []
        for (offset, key) in keys.enumerated() {
            var reference: EventHotKeyRef?
            let id = EventHotKeyID(signature: 0x53424F50, id: UInt32(offset + 1))
            let result = RegisterEventHotKey(key, UInt32(controlKey | optionKey), id,
                GetApplicationEventTarget(), 0, &reference)
            if result == noErr, let reference { references.append(reference) }
            else { failures.append("⌃⌥\(offset + 1)") }
        }
        return failures.isEmpty ? nil : "Shortcuts already in use: \(failures.joined(separator: ", ")). Menu-bar capture remains available."
    }

    func unregister() {
        references.forEach { UnregisterEventHotKey($0) }
        references.removeAll()
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }
}

@MainActor
final class PinWindowController: NSWindowController {
    init(image: CGImage) {
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1400, height: 900)
        let scale = min(1, min(520 / CGFloat(image.width), 500 / CGFloat(image.height)))
        let size = CGSize(width: max(140, CGFloat(image.width) * scale), height: max(100, CGFloat(image.height) * scale))
        let panel = NSPanel(contentRect: CGRect(origin: CGPoint(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2), size: size),
            styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Pinned reference — Screenboop"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.minSize = CGSize(width: 140, height: 100)
        let view = NSView(frame: CGRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        view.layer?.masksToBounds = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let imageView = NSImageView(frame: view.bounds)
        imageView.image = NSImage(cgImage: image, size: .zero)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        view.addSubview(imageView)
        let close = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close pinned image")!, target: nil, action: #selector(closePin(_:)))
        close.isBordered = false
        close.contentTintColor = .white
        close.wantsLayer = true
        close.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        close.layer?.cornerRadius = 12
        close.frame = CGRect(x: 8, y: size.height - 32, width: 24, height: 24)
        close.autoresizingMask = [.minYMargin]
        close.toolTip = "Close pinned reference"
        view.addSubview(close)
        panel.contentView = view
        super.init(window: panel)
        close.target = self
    }
    required init?(coder: NSCoder) { nil }
    @objc private func closePin(_ sender: Any?) { window?.close() }
}
