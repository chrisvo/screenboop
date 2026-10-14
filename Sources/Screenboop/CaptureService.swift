import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import ImageIO

@MainActor
final class CaptureService {
    var onStatus: ((String) -> Void)?
    private(set) var isCapturing = false

    private var captureTask: Task<CGImage?, Error>?
    private var screenshotJob: ScreenshotJob?
    private var selector: CaptureRegionSelector?
    private var progress: CaptureProgressPanel?
    private var userCancelled = false

    func capture(_ mode: CaptureMode) async throws -> CGImage? {
        guard !isCapturing else {
            throw ScreenboopError.message("A capture is already running. Finish or cancel it first.")
        }
        isCapturing = true
        userCancelled = false
        let task = Task { @MainActor [weak self] () throws -> CGImage? in
            guard let self else { throw CancellationError() }
            return try await self.perform(mode)
        }
        captureTask = task
        defer {
            selector?.close()
            progress?.close()
            selector = nil
            progress = nil
            screenshotJob = nil
            captureTask = nil
            isCapturing = false
        }
        do {
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch is CancellationError {
            if userCancelled { return nil }
            throw CancellationError()
        }
    }

    func cancel() {
        guard isCapturing else { return }
        userCancelled = true
        captureTask?.cancel()
        screenshotJob?.cancel()
        selector?.cancel()
        progress?.close()
    }

    private func perform(_ mode: CaptureMode) async throws -> CGImage? {
        try Task.checkCancellation()
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw ScreenboopError.message("Screen Recording permission is required. Open System Settings → Privacy & Security → Screen & System Audio Recording (Screen Recording on older macOS), enable screenboop, then quit and reopen the app if macOS requests it. Retry the capture afterwards.")
        }
        try Task.checkCancellation()
        switch mode {
        case .area:
            onStatus?("Drag an area to capture. Press Escape to cancel.")
            return try await screenshot(arguments: ["-i", "-s", "-x"], interactive: true)
        case .window:
            onStatus?("Click a window to capture. Press Escape to cancel.")
            return try await screenshot(arguments: ["-i", "-w", "-o", "-x"], interactive: true)
        case .fullscreen:
            onStatus?("Capturing the main display…")
            return try await screenshot(arguments: ["-m", "-x"], interactive: false)
        case .delayed:
            for seconds in stride(from: 5, through: 1, by: -1) {
                onStatus?("Capturing the main display in \(seconds) seconds…")
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            return try await screenshot(arguments: ["-m", "-x"], interactive: false)
        case .scrolling:
            return try await scrollingCapture()
        }
    }

    private func screenshot(arguments: [String], interactive: Bool) async throws -> CGImage? {
        try Task.checkCancellation()
        let job = ScreenshotJob(arguments: arguments, interactive: interactive)
        screenshotJob = job
        defer { screenshotJob = nil }
        let image = try await job.run()
        try Task.checkCancellation()
        return image
    }

    private func scrollingCapture() async throws -> CGImage {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            throw ScreenboopError.message("Scrolling capture requires Accessibility permission to send scroll events. Open System Settings → Privacy & Security → Accessibility, enable screenboop, and retry. screenboop does not change this setting for you.")
        }
        onStatus?("Drag a rectangle inside the scrollable content on one display. Escape cancels.")
        let regionSelector = CaptureRegionSelector { [weak self] in self?.cancel() }
        selector = regionSelector
        let region = try await regionSelector.select()
        selector = nil
        try Task.checkCancellation()
        let target = try CaptureScrollTarget.at(region.center)
        let panel = CaptureProgressPanel(region: region.appKitRect) { [weak self] in self?.cancel() }
        progress = panel
        defer { panel.close() }
        let rectArgument = "-R\(Int(region.quartzRect.origin.x)),\(Int(region.quartzRect.origin.y)),\(Int(region.quartzRect.width)),\(Int(region.quartzRect.height))"
        panel.update("Preparing scrolling capture…")
        panel.hide()
        try await Task.sleep(nanoseconds: 120_000_000)
        guard let first = try await screenshot(arguments: ["-x", rectArgument], interactive: false) else {
            throw ScreenboopError.message("The selected region could not be captured.")
        }
        let session = try await captureComputation { try ScrollStitcher.Session(first) }
        var appended = 0
        var reachedBottom = false
        let scrollDistance = Int32(max(48, min(480, region.quartzRect.height * 0.52)))
        for frameNumber in 2...20 {
            try Task.checkCancellation()
            panel.update("Capturing frame \(frameNumber) of 20…")
            onStatus?("Scrolling capture: frame \(frameNumber) of 20. Escape cancels.")
            panel.hide()
            try await Task.sleep(nanoseconds: 90_000_000)
            try target.ensureStillAt(region.center)
            try postScroll(at: region.center, distance: scrollDistance)
            try await Task.sleep(nanoseconds: 500_000_000)
            try target.ensureStillAt(region.center)
            guard let next = try await screenshot(arguments: ["-x", rectArgument], interactive: false) else {
                throw ScreenboopError.message("A scrolling capture frame was not produced.")
            }
            panel.update("Aligning frame \(frameNumber)…")
            let moved = try await captureComputation { try session.append(next) }
            if !moved {
                reachedBottom = true
                break
            }
            appended += 1
        }
        try Task.checkCancellation()
        guard appended > 0 else {
            throw ScreenboopError.message("The selected region did not move when scrolled. It may already be at the bottom, or the pointer may not be over scrollable content. Select the content area and try again.")
        }
        panel.update("Building the stitched image…")
        let image = try await captureComputation { try session.finish() }
        onStatus?(reachedBottom ? "Scrolling capture complete; the bottom was detected." : "Scrolling capture complete; stopped at the 20-frame limit.")
        return image
    }

    private func postScroll(at point: CGPoint, distance: Int32) throws {
        try Task.checkCancellation()
        guard AXIsProcessTrusted() else {
            throw ScreenboopError.message("Accessibility permission was revoked. Enable screenboop in System Settings → Privacy & Security → Accessibility and retry.")
        }
        guard let source = CGEventSource(stateID: .privateState),
              let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left),
              let scroll = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1, wheel1: -distance, wheel2: 0, wheel3: 0) else {
            throw ScreenboopError.message("macOS could not create the scrolling input events.")
        }
        // The capture action authorizes input only at the selected rectangle's center.
        // Moving first is required because some apps hit-test scrolls at the cursor.
        move.post(tap: .cghidEventTap)
        scroll.location = point
        scroll.post(tap: .cghidEventTap)
    }
}

// Pixel conversion, matching, image decoding and subprocess lifetime work never run
// on the main actor. Explicitly forward cancellation to the otherwise unstructured task.
private func captureComputation<T>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    let task = Task.detached(priority: .userInitiated, operation: body)
    return try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
}

private final class ScreenshotJob: @unchecked Sendable {
    private let queue = DispatchQueue(label: "screenboop.screenshot", qos: .userInitiated)
    private let lock = NSLock()
    private let arguments: [String]
    private let interactive: Bool
    private var cancelled = false
    private var continuation: CheckedContinuation<CGImage?, Error>?
    // The remaining lifetime state is accessed exclusively on queue.
    private var process: Process?
    private var directory: URL?
    private var errorHandle: FileHandle?
    private var killWork: DispatchWorkItem?

    init(arguments: [String], interactive: Bool) {
        self.arguments = arguments
        self.interactive = interactive
    }

    func run() async throws -> CGImage? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                lock.unlock()
                queue.async { self.start() }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        queue.async {
            guard let process = self.process, process.isRunning else { return }
            process.terminate()
            let killWork = DispatchWorkItem { [weak self, weak process] in
                guard let self, let process, self.process === process, process.isRunning else { return }
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
            self.killWork?.cancel()
            self.killWork = killWork
            self.queue.asyncAfter(deadline: .now() + 1, execute: killWork)
        }
    }

    private var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private func start() {
        if wasCancelled {
            complete(.failure(CancellationError()))
            return
        }
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("screenboop-\(UUID().uuidString)", isDirectory: true)
            self.directory = directory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let imageURL = directory.appendingPathComponent("capture.png")
            let errorURL = directory.appendingPathComponent("stderr.txt")
            guard FileManager.default.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw ScreenboopError.message("Could not create a private capture log file.")
            }
            let errorHandle = try FileHandle(forWritingTo: errorURL)
            self.errorHandle = errorHandle
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = arguments + ["-t", "png", imageURL.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errorHandle
            process.terminationHandler = { [weak self] process in
                guard let self else { return }
                self.queue.async { self.terminated(process, imageURL: imageURL, errorURL: errorURL) }
            }
            self.process = process
            try process.run()
            // Cancellation can arrive during launch, before Process.isRunning is true.
            if wasCancelled { cancel() }
        } catch {
            complete(.failure(wasCancelled ? CancellationError() : error))
        }
    }

    private func terminated(_ process: Process, imageURL: URL, errorURL: URL) {
        if wasCancelled {
            complete(.failure(CancellationError()))
            return
        }
        do {
            try errorHandle?.close()
            errorHandle = nil
            let logHandle = try FileHandle(forReadingFrom: errorURL)
            let logData = try logHandle.read(upToCount: 65_536) ?? Data()
            try logHandle.close()
            let diagnostic = (String(data: logData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let exists = FileManager.default.fileExists(atPath: imageURL.path)
            if interactive, !exists, process.terminationReason == .exit,
               (process.terminationStatus == 0 || process.terminationStatus == 1), diagnostic.isEmpty {
                guard CGPreflightScreenCaptureAccess() else {
                    throw ScreenboopError.message("Screen Recording permission is no longer available. Enable screenboop in System Settings → Privacy & Security → Screen & System Audio Recording, then reopen the app if macOS requests it.")
                }
                // macOS versions return either 0 or 1 when the picker is dismissed.
                // No output is also possible when the user chooses clipboard-only capture.
                complete(.success(nil))
                return
            }
            guard process.terminationReason == .exit, process.terminationStatus == 0, exists else {
                let explanation = diagnostic.isEmpty ? "macOS did not produce a screenshot (exit \(process.terminationStatus)). If you used Control to copy to the clipboard, retry without Control." : diagnostic
                throw ScreenboopError.message("Capture failed: \(explanation)")
            }
            guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                throw ScreenboopError.message("The screenshot file could not be decoded.")
            }
            try ScrollStitcher.validate(width: image.width, height: image.height)
            if wasCancelled { throw CancellationError() }
            complete(.success(image))
        } catch {
            complete(.failure(error))
        }
    }

    private func complete(_ result: Result<CGImage?, Error>) {
        killWork?.cancel()
        killWork = nil
        process?.terminationHandler = nil
        process = nil
        try? errorHandle?.close()
        errorHandle = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private struct CaptureRegion {
    let appKitRect: CGRect
    let quartzRect: CGRect
    var center: CGPoint { CGPoint(x: quartzRect.midX, y: quartzRect.midY) }
}

private struct CaptureScrollTarget {
    let windowID: CGWindowID
    let ownerPID: pid_t

    static func at(_ point: CGPoint) throws -> CaptureScrollTarget {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            throw ScreenboopError.message("macOS could not identify the window under the scrolling region.")
        }
        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? Int,
                  pid != Int(getpid()),
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.contains(point),
                  let id = window[kCGWindowNumber as String] as? UInt32,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
            return CaptureScrollTarget(windowID: id, ownerPID: pid_t(pid))
        }
        throw ScreenboopError.message("Select scrollable content inside another app's window, not the desktop or screenboop.")
    }

    func ensureStillAt(_ point: CGPoint) throws {
        let current = try Self.at(point)
        guard current.windowID == windowID, current.ownerPID == ownerPID else {
            throw ScreenboopError.message("Scrolling capture stopped because another window covered the selected region. Keep the target window in place and retry.")
        }
    }
}

@MainActor
private final class CaptureOverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class CaptureRegionSelector {
    private var windows: [CaptureOverlayWindow] = []
    private var views: [CaptureRegionView] = []
    private var continuation: CheckedContinuation<CaptureRegion, Error>?
    private var start: CGPoint?
    private var startingScreen: CGRect?
    private var selectedRect: CGRect?
    private let onCancel: () -> Void

    init(onCancel: @escaping () -> Void) { self.onCancel = onCancel }

    func select() async throws -> CaptureRegion {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                for screen in NSScreen.screens {
                    let window = CaptureOverlayWindow(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                    window.setFrame(screen.frame, display: false)
                    window.level = .screenSaver
                    window.isOpaque = false
                    window.backgroundColor = .clear
                    window.hasShadow = false
                    window.isReleasedWhenClosed = false
                    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                    let view = CaptureRegionView(frame: CGRect(origin: .zero, size: screen.frame.size), screenFrame: screen.frame, selector: self)
                    window.contentView = view
                    window.makeFirstResponder(view)
                    windows.append(window)
                    views.append(view)
                    window.orderFrontRegardless()
                }
                if windows.isEmpty {
                    finish(.failure(ScreenboopError.message("No display is available for region selection.")))
                } else {
                    windows.first?.makeKey()
                    NSCursor.crosshair.set()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func begin(at point: CGPoint, screen: CGRect) {
        start = point
        startingScreen = screen
        selectedRect = nil
        update(at: point)
    }

    func update(at point: CGPoint) {
        guard let start, let screen = startingScreen else { return }
        let point = CGPoint(x: min(screen.maxX, max(screen.minX, point.x)), y: min(screen.maxY, max(screen.minY, point.y)))
        selectedRect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(start.x - point.x), height: abs(start.y - point.y))
        for view in views {
            view.selection = selectedRect
            view.needsDisplay = true
        }
    }

    func end(at point: CGPoint) {
        update(at: point)
        guard let selectedRect, selectedRect.width >= 48, selectedRect.height >= 48 else {
            finish(.failure(ScreenboopError.message("Choose a scrolling region at least 48 × 48 screen points. Keep the rectangle inside one display and exclude fixed sidebars when possible.")))
            return
        }
        guard let mainScreen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID()
        }) else {
            finish(.failure(ScreenboopError.message("Could not map the selected display to screen capture coordinates.")))
            return
        }
        // AppKit's global origin is bottom-left; Quartz's is the main display's
        // top-left. This also preserves negative origins for secondary displays.
        let rect = selectedRect.integral
        let quartz = CGRect(x: rect.minX - mainScreen.frame.minX, y: mainScreen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        finish(.success(CaptureRegion(appKitRect: rect, quartzRect: quartz)))
    }

    func requestCancel() { onCancel() }
    func cancel() { finish(.failure(CancellationError())) }

    func close() {
        for window in windows { window.orderOut(nil); window.close() }
        windows.removeAll()
        views.removeAll()
        NSCursor.arrow.set()
    }

    private func finish(_ result: Result<CaptureRegion, Error>) {
        let continuation = self.continuation
        self.continuation = nil
        close()
        continuation?.resume(with: result)
    }
}

@MainActor
private final class CaptureRegionView: NSView {
    let screenFrame: CGRect
    weak var selector: CaptureRegionSelector?
    var selection: CGRect?
    override var acceptsFirstResponder: Bool { true }

    init(frame: CGRect, screenFrame: CGRect, selector: CaptureRegionSelector) {
        self.screenFrame = screenFrame
        self.selector = selector
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { return nil }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        selector?.begin(at: screenPoint(event), screen: screenFrame)
    }
    override func mouseDragged(with event: NSEvent) { selector?.update(at: screenPoint(event)) }
    override func mouseUp(with event: NSEvent) { selector?.end(at: screenPoint(event)) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { selector?.requestCancel() }
    }
    override func cancelOperation(_ sender: Any?) { selector?.requestCancel() }

    private func screenPoint(_ event: NSEvent) -> CGPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }

    override func draw(_ dirtyRect: NSRect) {
        let shade = NSBezierPath(rect: bounds)
        if let selection {
            let local = selection.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
            shade.appendRect(local)
            shade.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.32).setFill()
            shade.fill()
            NSColor.systemPurple.setStroke()
            let border = NSBezierPath(rect: local)
            border.lineWidth = 2
            border.stroke()
        } else {
            NSColor.black.withAlphaComponent(0.32).setFill()
            shade.fill()
        }
        let text = "Drag inside one display's scrollable content · Escape cancels"
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attributes)
        let rect = CGRect(x: max(16, (bounds.width - size.width) / 2), y: bounds.height - 88, width: min(size.width, bounds.width - 32), height: size.height)
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }
}

@MainActor
private final class CaptureProgressPanel: NSObject {
    private let panel: NSPanel
    private let label: NSTextField
    private let onCancel: () -> Void
    private var localMonitor: Any?
    private var globalMonitor: Any?

    init(region: CGRect, onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 350, height: 106), styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        label = NSTextField(labelWithString: "Preparing scrolling capture…")
        super.init()
        panel.title = "screenboop scrolling capture"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = true
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 350, height: 106))
        label.frame = CGRect(x: 18, y: 63, width: 314, height: 20)
        content.addSubview(label)
        let button = NSButton(title: "Cancel (Esc)", target: self, action: #selector(cancelPressed))
        button.bezelStyle = .rounded
        button.frame = CGRect(x: 222, y: 16, width: 112, height: 32)
        content.addSubview(button)
        panel.contentView = content
        let instruction = NSTextField(labelWithString: "Keep the target window in place.")
        instruction.font = .systemFont(ofSize: 11)
        instruction.textColor = .secondaryLabelColor
        instruction.frame = CGRect(x: 18, y: 23, width: 205, height: 16)
        content.addSubview(instruction)
        position(avoiding: region)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.onCancel(); return nil }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor [weak self] in self?.onCancel() }
            }
        }
        panel.orderFrontRegardless()
    }

    func update(_ text: String) {
        label.stringValue = text
        panel.orderFrontRegardless()
    }
    func hide() { panel.orderOut(nil) }
    @objc private func cancelPressed() { onCancel() }

    func close() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        panel.orderOut(nil)
        panel.close()
    }

    private func position(avoiding region: CGRect) {
        let size = panel.frame.size
        for screen in NSScreen.screens {
            let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
            let candidates = [CGPoint(x: visible.minX, y: visible.maxY - size.height), CGPoint(x: visible.maxX - size.width, y: visible.maxY - size.height), CGPoint(x: visible.minX, y: visible.minY), CGPoint(x: visible.maxX - size.width, y: visible.minY)]
            if let origin = candidates.first(where: { visible.contains(CGRect(origin: $0, size: size)) && !region.intersects(CGRect(origin: $0, size: size)) }) {
                panel.setFrameOrigin(origin)
                return
            }
        }
        // A full-display region may leave no free corner. The panel is always
        // hidden before both input and capture, so it cannot intercept or appear.
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(region) }) {
            panel.setFrameOrigin(CGPoint(x: screen.visibleFrame.minX + 12, y: screen.visibleFrame.maxY - size.height - 12))
        }
    }
}

/// Matches vertical translations, rejects ambiguous/repetitive content, and keeps
/// fixed headers/footers only once. No AppKit or screen access is used here.
enum ScrollStitcher {
    static func stitch(_ images: [CGImage]) throws -> CGImage {
        guard images.count >= 2 else {
            throw ScreenboopError.message("Stitching requires at least two overlapping frames.")
        }
        let session = try Session(images[0])
        for image in images.dropFirst() {
            try Task.checkCancellation()
            _ = try session.append(image)
        }
        return try session.finish()
    }

    fileprivate static func validate(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= 32_768, height <= 32_768, width <= 100_000_000 / height else {
            throw ScreenboopError.message("The capture is too large. Images are limited to 32,768 pixels per side and 100 million total pixels. Select a smaller region.")
        }
    }

    // A session has one sequential owner: either stitch() or awaited background
    // operations from CaptureService. It is never mutated by concurrent tasks.
    fileprivate final class Session: @unchecked Sendable {
        private var previous: Frame
        private var parts: [CGImage]
        private var outputHeight: Int
        private var fixedTop = 0
        private var fixedBottom = 0
        private var hasMoved = false

        init(_ first: CGImage) throws {
            previous = try Frame(first)
            parts = [first]
            outputHeight = first.height
        }

        @discardableResult
        func append(_ image: CGImage) throws -> Bool {
            try Task.checkCancellation()
            guard image.width == previous.image.width else {
                throw ScreenboopError.message("Scrolling frames have different widths. Keep the window and selected region unchanged.")
            }
            let next = try Frame(image)
            if try ScrollStitcher.stationary(previous, next) { return false }
            let match = try ScrollStitcher.alignment(previous, next, knownInsets: hasMoved ? (fixedTop, fixedBottom) : nil)
            let top = hasMoved ? fixedTop : match.top
            let bottom = hasMoved ? fixedBottom : match.bottom
            let start = previous.image.height - match.shift - bottom
            let length = image.height - bottom - start
            guard start >= top, length > 0, start + length <= image.height else {
                throw ScreenboopError.message("The scrolling frames do not have a usable vertical overlap.")
            }
            let retainedHeight = outputHeight - (hasMoved ? 0 : bottom)
            let totalHeight = retainedHeight + length + bottom
            try ScrollStitcher.validate(width: image.width, height: totalHeight)
            if !hasMoved, bottom > 0 {
                parts[0] = try ScrollStitcher.ownedStrip(previous.image, start: 0, height: previous.image.height - bottom)
                outputHeight -= bottom
            }
            let strip = try ScrollStitcher.ownedStrip(image, start: start, height: length)
            parts.append(strip)
            outputHeight += length
            fixedTop = top
            fixedBottom = bottom
            previous = next
            hasMoved = true
            return true
        }

        func finish() throws -> CGImage {
            try Task.checkCancellation()
            if !hasMoved { return previous.image }
            let totalHeight = outputHeight + fixedBottom
            try ScrollStitcher.validate(width: previous.image.width, height: totalHeight)
            let context = try ScrollStitcher.bitmap(width: previous.image.width, height: totalHeight)
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            var top = 0
            for image in parts {
                try Task.checkCancellation()
                context.draw(image, in: CGRect(x: 0, y: totalHeight - top - image.height, width: image.width, height: image.height))
                top += image.height
            }
            if fixedBottom > 0 {
                let footer = try ScrollStitcher.ownedStrip(previous.image, start: previous.image.height - fixedBottom, height: fixedBottom)
                context.draw(footer, in: CGRect(x: 0, y: 0, width: footer.width, height: footer.height))
            }
            guard let image = context.makeImage() else {
                throw ScreenboopError.message("Could not create the stitched image.")
            }
            return image
        }
    }

    private struct Sample {
        let r: UInt8
        let g: UInt8
        let b: UInt8
        let weight: UInt8
    }

    private struct Frame {
        let image: CGImage
        let samples: [Sample]
        let columns: Int
        let pixelContext: CGContext
        let pixels: UnsafePointer<UInt8>

        init(_ image: CGImage) throws {
            try Task.checkCancellation()
            try ScrollStitcher.validate(width: image.width, height: image.height)
            self.image = image
            let columns = min(64, image.width)
            self.columns = columns
            let context = try ScrollStitcher.bitmap(width: image.width, height: image.height)
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let data = context.data else {
                throw ScreenboopError.message("Could not access pixels for scroll alignment.")
            }
            let bytes = data.assumingMemoryBound(to: UInt8.self)
            let inset = min(24, image.width / 40)
            let span = max(1, image.width - 1 - inset * 2)
            var samples: [Sample] = []
            samples.reserveCapacity(columns * image.height)
            for y in 0..<image.height {
                if y & 63 == 0 { try Task.checkCancellation() }
                for column in 0..<columns {
                    let x = inset + (columns == 1 ? 0 : column * span / (columns - 1))
                    let offset = (y * image.width + x) * 4
                    let nearbyX = min(image.width - 1, x + 3)
                    let nearbyY = min(image.height - 1, y + 2)
                    let horizontal = (y * image.width + nearbyX) * 4
                    let vertical = (nearbyY * image.width + x) * 4
                    var contrast = 0
                    for channel in 0..<3 {
                        contrast = max(contrast, max(abs(Int(bytes[offset + channel]) - Int(bytes[horizontal + channel])), abs(Int(bytes[offset + channel]) - Int(bytes[vertical + channel]))))
                    }
                    samples.append(Sample(r: bytes[offset], g: bytes[offset + 1], b: bytes[offset + 2], weight: contrast > 12 ? 4 : 1))
                }
            }
            self.samples = samples
            self.pixelContext = context
            self.pixels = UnsafePointer(bytes)
        }
    }

    private struct Score {
        let shift: Int
        let error: Double
        let mismatches: Double
    }

    private struct Match {
        let shift: Int
        let top: Int
        let bottom: Int
    }

    private static func stationary(_ old: Frame, _ new: Frame) throws -> Bool {
        guard old.image.height == new.image.height else { return false }
        var difference = 0
        var changed = 0
        var count = 0
        let step = max(1, old.image.height / 320)
        for y in stride(from: 0, to: old.image.height, by: step) {
            if y & 63 == 0 { try Task.checkCancellation() }
            for x in 0..<old.columns {
                let a = old.samples[y * old.columns + x]
                let b = new.samples[y * new.columns + x]
                let delta = abs(Int(a.r) - Int(b.r)) + abs(Int(a.g) - Int(b.g)) + abs(Int(a.b) - Int(b.b))
                difference += delta
                if delta > 36 { changed += 1 }
                count += 1
            }
        }
        guard Double(difference) / Double(max(1, count * 3)) < 0.8, Double(changed) / Double(max(1, count)) < 0.002 else { return false }
        // Confirm over all pixels: sparse sampling alone can miss a narrow moving
        // column and must not incorrectly report that the bottom was reached.
        return try withExtendedLifetime((old.pixelContext, new.pixelContext)) {
            let pixels = old.image.width * old.image.height
            let allowedChanged = max(8, pixels / 100_000)
            let allowedDifference = Int(Double(pixels * 3) * 0.8)
            var changed = 0
            var difference = 0
            for pixel in 0..<pixels {
                if pixel & 16_383 == 0 { try Task.checkCancellation() }
                let offset = pixel * 4
                let delta = abs(Int(old.pixels[offset]) - Int(new.pixels[offset]))
                    + abs(Int(old.pixels[offset + 1]) - Int(new.pixels[offset + 1]))
                    + abs(Int(old.pixels[offset + 2]) - Int(new.pixels[offset + 2]))
                difference += delta
                if delta > 36 { changed += 1 }
                if changed > allowedChanged || difference > allowedDifference { return false }
            }
            return true
        }
    }

    private static func alignment(_ old: Frame, _ new: Frame, knownInsets: (Int, Int)?) throws -> Match {
        let height = min(old.image.height, new.image.height)
        let minimumOverlap = max(1, height / 6)
        guard height > minimumOverlap else {
            throw ScreenboopError.message("The selected scrolling region is too short to align reliably.")
        }
        let guesses = knownInsets ?? staticInsets(old, new)
        let top = guesses.0
        let bottom = guesses.1
        if knownInsets != nil, !bandsRemainStatic(old, new, top: top, bottom: bottom) {
            throw ScreenboopError.message("A fixed header or footer changed during scrolling capture. Select only the scrolling content and retry.")
        }
        let maximumShift = old.image.height - top - bottom - minimumOverlap
        guard maximumShift >= 1 else {
            throw ScreenboopError.message("There is not enough moving content to align the scrolling frames.")
        }
        var candidates: [Score] = []
        candidates.reserveCapacity(14)
        var preceding: Score?
        var beforePreceding = Double.infinity
        for shift in 1...maximumShift {
            if shift & 63 == 0 { try Task.checkCancellation() }
            let current = score(old, new, shift: shift, top: top, bottom: bottom, rows: 40, columnStep: 2)
            if let preceding, preceding.error <= beforePreceding, preceding.error <= current.error {
                insertCandidate(preceding, into: &candidates)
            }
            beforePreceding = preceding?.error ?? .infinity
            preceding = current
        }
        if let preceding, preceding.error <= beforePreceding { insertCandidate(preceding, into: &candidates) }
        let refined = candidates.map { score(old, new, shift: $0.shift, top: top, bottom: bottom, rows: 160, columnStep: 1) }.sorted { $0.error < $1.error }
        guard let best = refined.first, best.error <= 7.5, best.mismatches <= 0.14 else {
            throw ScreenboopError.message("The scrolling frames could not be aligned confidently. Select only the moving content, avoid animations or fixed sidebars, and retry. No unmatched frames were appended.")
        }
        let unshifted = score(old, new, shift: 0, top: top, bottom: bottom, rows: 160, columnStep: 1)
        guard unshifted.error - best.error > max(0.6, best.error * 0.2) else {
            throw ScreenboopError.message("The selected area has too little distinctive movement to establish a reliable vertical overlap. Select more of the scrolling content and retry.")
        }
        let separation = max(3, height / 512)
        if let alternate = refined.first(where: { abs($0.shift - best.shift) >= separation }), alternate.error - best.error < max(1.1, best.error * 0.3) {
            throw ScreenboopError.message("The scrolling overlap is ambiguous (for example, repeated rows or nearly blank content). Select a region with more distinctive content and retry. No unmatched frames were appended.")
        }
        if let knownInsets { return Match(shift: best.shift, top: knownInsets.0, bottom: knownInsets.1) }
        // Blank margins alone are not evidence of fixed UI. Only retain bands
        // whose same-position pixels contradict the detected content translation.
        let confirmedTop = bandContradictsTranslation(old, new, range: 0..<top, shift: best.shift) ? top : 0
        let confirmedBottom = bandContradictsTranslation(old, new, range: (height - bottom)..<height, shift: best.shift) ? bottom : 0
        let verified = score(old, new, shift: best.shift, top: confirmedTop, bottom: confirmedBottom, rows: 160, columnStep: 1)
        guard verified.error <= 7.5, verified.mismatches <= 0.14 else {
            throw ScreenboopError.message("The selected area contains non-scrolling regions that prevent a reliable stitch. Select just the scrolling content and retry.")
        }
        return Match(shift: best.shift, top: confirmedTop, bottom: confirmedBottom)
    }

    private static func insertCandidate(_ score: Score, into candidates: inout [Score]) {
        let index = candidates.firstIndex(where: { $0.error > score.error }) ?? candidates.count
        guard index < 14 else { return }
        candidates.insert(score, at: index)
        if candidates.count > 14 { candidates.removeLast() }
    }

    private static func score(_ old: Frame, _ new: Frame, shift: Int, top: Int, bottom: Int, rows: Int, columnStep: Int) -> Score {
        let end = min(new.image.height - bottom, old.image.height - bottom - shift)
        guard end > top else { return Score(shift: shift, error: .infinity, mismatches: 1) }
        let step = max(1, (end - top) / rows)
        var difference = 0
        var mismatch = 0
        var weights = 0
        for y in stride(from: top, to: end, by: step) {
            for x in stride(from: 0, to: old.columns, by: columnStep) {
                let a = old.samples[(y + shift) * old.columns + x]
                let b = new.samples[y * new.columns + x]
                let delta = abs(Int(a.r) - Int(b.r)) + abs(Int(a.g) - Int(b.g)) + abs(Int(a.b) - Int(b.b))
                let weight = Int(max(a.weight, b.weight))
                difference += delta * weight
                if delta > 54 { mismatch += weight }
                weights += weight
            }
        }
        return Score(shift: shift, error: Double(difference) / Double(max(1, weights * 3)), mismatches: Double(mismatch) / Double(max(1, weights)))
    }

    private static func rowDifference(_ old: Frame, _ new: Frame, oldY: Int, newY: Int) -> Double {
        var difference = 0
        for x in 0..<old.columns {
            let a = old.samples[oldY * old.columns + x]
            let b = new.samples[newY * new.columns + x]
            difference += abs(Int(a.r) - Int(b.r)) + abs(Int(a.g) - Int(b.g)) + abs(Int(a.b) - Int(b.b))
        }
        return Double(difference) / Double(old.columns * 3)
    }

    private static func staticInsets(_ old: Frame, _ new: Frame) -> (Int, Int) {
        guard old.image.height == new.image.height else { return (0, 0) }
        let limit = old.image.height / 4
        var top = 0
        while top < limit, rowDifference(old, new, oldY: top, newY: top) < 1.5 { top += 1 }
        var bottom = 0
        while bottom < limit, rowDifference(old, new, oldY: old.image.height - bottom - 1, newY: new.image.height - bottom - 1) < 1.5 { bottom += 1 }
        return (top, bottom)
    }

    private static func bandsRemainStatic(_ old: Frame, _ new: Frame, top: Int, bottom: Int) -> Bool {
        guard old.image.height == new.image.height || (top == 0 && bottom == 0) else { return false }
        for y in stride(from: 0, to: top, by: max(1, top / 24)) {
            if rowDifference(old, new, oldY: y, newY: y) > 3 { return false }
        }
        if bottom > 0 {
            for y in stride(from: old.image.height - bottom, to: old.image.height, by: max(1, bottom / 24)) {
                if rowDifference(old, new, oldY: y, newY: y) > 3 { return false }
            }
        }
        return true
    }

    private static func bandContradictsTranslation(_ old: Frame, _ new: Frame, range: Range<Int>, shift: Int) -> Bool {
        guard !range.isEmpty else { return false }
        var contradictoryRows = 0
        for y in range {
            // For a footer compare its old position against the new shifted row;
            // for a header compare its new position against the old shifted row.
            if y + shift < old.image.height {
                if rowDifference(old, new, oldY: y + shift, newY: y) > 5 { contradictoryRows += 1 }
            } else if y - shift >= 0 {
                if rowDifference(old, new, oldY: y, newY: y - shift) > 5 { contradictoryRows += 1 }
            }
            if contradictoryRows >= 2 { return true }
        }
        return false
    }

    private static func srgb() throws -> CGColorSpace {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw ScreenboopError.message("Could not create the image color space.")
        }
        return space
    }

    private static func bitmap(width: Int, height: Int) throws -> CGContext {
        try validate(width: width, height: height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: try srgb(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw ScreenboopError.message("Could not allocate the stitched image. Select a smaller capture region.")
        }
        return context
    }

    private static func ownedStrip(_ image: CGImage, start: Int, height: Int) throws -> CGImage {
        guard start >= 0, height > 0, start <= image.height - height else {
            throw ScreenboopError.message("A scrolling image strip is outside its frame.")
        }
        if start == 0, height == image.height { return image }
        guard let cropped = image.cropping(to: CGRect(x: 0, y: start, width: image.width, height: height)) else {
            throw ScreenboopError.message("Could not crop the aligned scrolling frame.")
        }
        // Materialize only the retained strip, releasing the rest of old frames.
        let context = try bitmap(width: image.width, height: height)
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: image.width, height: height))
        guard let strip = context.makeImage() else {
            throw ScreenboopError.message("Could not retain the aligned scrolling frame.")
        }
        return strip
    }
}
