import AppKit
import SwiftUI

struct CanvasBridge: NSViewRepresentable {
    @ObservedObject var store: AppStore
    func makeNSView(context: Context) -> CanvasScrollView {
        let scroll = CanvasScrollView()
        let canvas = EditorCanvas(store: store)
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        DispatchQueue.main.async { [weak scroll, weak canvas] in
            guard let scroll, let canvas else { return }
            canvas.relayout(viewport: scroll.contentSize)
            store.zoomToFit()
            scroll.window?.makeFirstResponder(canvas)
        }
        return scroll
    }
    func updateNSView(_ scroll: CanvasScrollView, context: Context) {
        guard let canvas = scroll.documentView as? EditorCanvas else { return }
        let changed = canvas.lastPreview !== store.preview || canvas.lastZoom != store.zoom || canvas.lastSelection != store.selectedID || canvas.lastRect != store.selectionRect
        canvas.lastPreview = store.preview; canvas.lastZoom = store.zoom
        canvas.lastSelection = store.selectedID; canvas.lastRect = store.selectionRect
        if changed { canvas.relayout(viewport: scroll.contentSize); canvas.needsDisplay = true }
    }
}

final class CanvasScrollView: NSScrollView {
    override func layout() {
        super.layout()
        (documentView as? EditorCanvas)?.relayout(viewport: contentSize)
    }
}

@MainActor
final class EditorCanvas: NSView {
    let store: AppStore
    var lastPreview: CGImage?
    var lastZoom: CGFloat = 0
    var lastSelection: UUID?
    var lastRect: CGRect?
    private var tracking: NSTrackingArea?
    private var draft: Markup?
    private var dragStart: CGPoint?
    private var movingMarkup: Markup?
    private var movingPreview: CGImage?
    private var draftSource: CGImage?
    private var movingOffset = CGPoint.zero
    private var spaceHeld = false
    private var panStart: CGPoint?
    private var panOrigin: CGPoint?
    private var pushedPanCursor = false
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(store: AppStore) {
        self.store = store
        super.init(frame: CGRect(x: 0, y: 0, width: 900, height: 650))
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { nil }

    var renderRect: CGRect {
        guard let image = store.preview else { return .zero }
        let size = CGSize(width: CGFloat(image.width) * store.zoom, height: CGFloat(image.height) * store.zoom)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }
    var imageOrigin: CGPoint {
        let style: BackdropStyle = store.document?.backdrop.style ?? BackdropStyle.none
        let padding = style == BackdropStyle.none ? 0 : ceil(store.document?.backdrop.padding ?? 0)
        return CGPoint(x: renderRect.minX + padding * store.zoom, y: renderRect.minY + padding * store.zoom)
    }
    func imagePoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: (point.x - imageOrigin.x) / store.zoom, y: (point.y - imageOrigin.y) / store.zoom)
    }
    func clamped(_ point: CGPoint) -> CGPoint {
        guard let size = store.document?.size else { return .zero }
        return CGPoint(x: min(max(0, point.x), size.width), y: min(max(0, point.y), size.height))
    }
    func relayout(viewport: CGSize) {
        store.viewport = viewport
        let image = store.preview
        let desired = CGSize(width: max(viewport.width, CGFloat(image?.width ?? 0) * store.zoom + 80),
            height: max(viewport.height, CGFloat(image?.height ?? 0) * store.zoom + 80))
        if frame.size != desired { setFrameSize(desired) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: spaceHeld ? .openHand : (store.tool == .select ? .arrow : .crosshair))
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.955, green: 0.956, blue: 0.966, alpha: 1).setFill()
        dirtyRect.fill()
        NSColor(srgbRed: 0.81, green: 0.82, blue: 0.86, alpha: 0.7).setFill()
        for x in stride(from: floor(dirtyRect.minX / 20) * 20, through: dirtyRect.maxX, by: 20) {
            for y in stride(from: floor(dirtyRect.minY / 20) * 20, through: dirtyRect.maxY, by: 20) {
                NSBezierPath(ovalIn: CGRect(x: x, y: y, width: 1.3, height: 1.3)).fill()
            }
        }
        guard let preview = movingPreview ?? store.preview, let document = store.document,
              let context = NSGraphicsContext.current?.cgContext else { return }
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowOffset = CGSize(width: 0, height: 3)
        shadow.shadowBlurRadius = 20; shadow.shadowColor = NSColor.black.withAlphaComponent(0.13); shadow.set()
        NSImage(cgImage: preview, size: CGSize(width: preview.width, height: preview.height))
            .draw(in: renderRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()
        context.saveGState()
        context.translateBy(x: imageOrigin.x, y: imageOrigin.y)
        context.scaleBy(x: store.zoom, y: store.zoom)
        context.clip(to: CGRect(origin: .zero, size: document.size))
        if var movingMarkup {
            movingMarkup.translate(by: movingOffset)
            ImageRenderer.drawMarkup(movingMarkup, over: draftSource ?? document.image, in: context)
        }
        if let draft { ImageRenderer.drawMarkup(draft, over: draftSource ?? document.image, in: context) }
        for mask in document.annotations where mask.tool == .redact && mask.id != movingMarkup?.id {
            ImageRenderer.drawMarkup(mask, over: document.image, in: context)
        }
        if var mask = movingMarkup, mask.tool == .redact {
            mask.translate(by: movingOffset)
            ImageRenderer.drawMarkup(mask, over: document.image, in: context)
        }
        if let selection = store.selectionRect { drawSelection(selection, in: context) }
        if let id = store.selectedID, let markup = document.annotations.first(where: { $0.id == id }) {
            drawSelection(markupBounds(markup).offsetBy(dx: movingOffset.x, dy: movingOffset.y), in: context)
        }
        context.restoreGState()
    }
    private func drawSelection(_ rect: CGRect, in context: CGContext) {
        context.saveGState()
        context.setStrokeColor(NSColor(srgbRed: 0.40, green: 0.34, blue: 0.95, alpha: 1).cgColor)
        context.setLineWidth(1.5 / store.zoom)
        context.setLineDash(phase: 0, lengths: [5 / store.zoom, 4 / store.zoom])
        context.stroke(rect)
        context.setFillColor(NSColor.white.cgColor)
        context.setLineDash(phase: 0, lengths: [])
        for point in [CGPoint(x: rect.minX,y: rect.minY), CGPoint(x: rect.maxX,y: rect.minY), CGPoint(x: rect.minX,y: rect.maxY), CGPoint(x: rect.maxX,y: rect.maxY)] {
            let handle = CGRect(x: point.x - 3 / store.zoom, y: point.y - 3 / store.zoom, width: 6 / store.zoom, height: 6 / store.zoom)
            context.fill(handle); context.stroke(handle)
        }
        context.restoreGState()
    }
    private func markupBounds(_ markup: Markup) -> CGRect {
        if markup.tool == .text {
            return CGRect(origin: markup.start, size: CGSize(width: max(60, CGFloat(markup.text.count) * max(16, markup.lineWidth * 5) * 0.6), height: max(24, markup.lineWidth * 6)))
        }
        if markup.tool == .number { return CGRect(x: markup.start.x - 20, y: markup.start.y - 20, width: 40, height: 40) }
        if markup.tool == .pen, let first = markup.points.first {
            return markup.points.reduce(CGRect(origin: first, size: CGSize(width: 1, height: 1))) { $0.union(CGRect(origin: $1, size: CGSize(width: 1, height: 1))) }.insetBy(dx: -markup.lineWidth, dy: -markup.lineWidth)
        }
        return markup.rect.insetBy(dx: -markup.lineWidth, dy: -markup.lineWidth)
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if spaceHeld { startPan(event); return }
        guard let document = store.document else { return }
        let point = imagePoint(event)
        guard CGRect(origin: .zero, size: document.size).contains(point) else { return }
        store.selectionRect = nil
        dragStart = point
        if store.tool == .select {
            if let markup = document.annotations.reversed().first(where: { markupBounds($0).insetBy(dx: -8 / store.zoom, dy: -8 / store.zoom).contains(point) }) {
                store.selectedID = markup.id
                movingMarkup = markup
                movingOffset = .zero
                do {
                    var background = document
                    background.annotations.removeAll { $0.id == markup.id }
                    movingPreview = try ImageRenderer.render(background)
                    if markup.tool == .blur || markup.tool == .magnifier {
                        draftSource = try ImageRenderer.effectSource(background)
                    }
                } catch {
                    movingMarkup = nil; dragStart = nil; store.report(error)
                }
            } else { store.selectedID = nil }
        } else if store.tool == .crop {
            store.selectedID = nil
        } else if store.tool == .text {
            let alert = NSAlert(); alert.messageText = "Add text"; alert.informativeText = "Text is rendered locally into your exported image."
            let input = NSTextField(frame: CGRect(x: 0, y: 0, width: 360, height: 28))
            input.placeholderString = "Your annotation"; alert.accessoryView = input
            alert.addButton(withTitle: "Add text"); alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = input
            if alert.runModal() == .alertFirstButtonReturn, !input.stringValue.isEmpty {
                store.commit(Markup(tool: .text, start: point, end: point, text: input.stringValue, color: store.color, lineWidth: store.lineWidth))
            }
            dragStart = nil
        } else if store.tool == .number {
            let next = document.annotations.filter { $0.tool == .number }.count + 1
            store.commit(Markup(tool: .number, start: point, end: point, text: String(next), color: store.color, lineWidth: store.lineWidth))
            dragStart = nil
        } else {
            store.selectedID = nil
            if store.tool == .blur || store.tool == .magnifier {
                do { draftSource = try ImageRenderer.effectSource(document) }
                catch { dragStart = nil; store.report(error); return }
            }
            draft = Markup(tool: store.tool, start: point, end: point, points: store.tool == .pen ? [point] : [], color: store.color, lineWidth: store.lineWidth)
        }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        if panStart != nil { continuePan(event); return }
        guard let start = dragStart else { return }
        var end = clamped(imagePoint(event))
        if event.modifierFlags.contains(.shift), draft?.tool == .rectangle || draft?.tool == .ellipse {
            let side = min(abs(end.x - start.x), abs(end.y - start.y))
            end = CGPoint(x: start.x + (end.x < start.x ? -side : side), y: start.y + (end.y < start.y ? -side : side))
        }
        if movingMarkup != nil {
            movingOffset = CGPoint(x: end.x - start.x, y: end.y - start.y)
        } else if store.tool == .crop || store.tool == .select {
            store.selectionRect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x-start.x), height: abs(end.y-start.y))
        } else if draft != nil {
            draft?.end = end
            if draft?.tool == .pen { draft?.points.append(end) }
        }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if panStart != nil { endPan(); return }
        if var movingMarkup {
            movingMarkup.translate(by: movingOffset)
            if movingOffset != .zero { store.replaceAnnotation(movingMarkup) }
        }
        if var draft {
            if draft.tool == .magnifier, draft.rect.width < 8 || draft.rect.height < 8 {
                draft.start = CGPoint(x: draft.start.x - 60, y: draft.start.y - 60)
                draft.end = CGPoint(x: draft.start.x + 120, y: draft.start.y + 120)
            }
            if draft.tool == .pen || draft.tool == .magnifier || hypot(draft.end.x - draft.start.x, draft.end.y - draft.start.y) > 2 {
                store.commit(draft)
            }
        }
        draft = nil; draftSource = nil; movingMarkup = nil; movingPreview = nil
        movingOffset = .zero; dragStart = nil
        needsDisplay = true
    }
    override func mouseMoved(with event: NSEvent) {
        let point = imagePoint(event)
        if let size = store.document?.size, CGRect(origin: .zero, size: size).contains(point) { store.sampleColor(at: point) }
    }
    override func mouseExited(with event: NSEvent) { store.hoverPosition = nil }
    private func startPan(_ event: NSEvent) {
        panStart = event.locationInWindow
        panOrigin = enclosingScrollView?.contentView.bounds.origin
        if !pushedPanCursor { NSCursor.closedHand.push(); pushedPanCursor = true }
    }
    private func continuePan(_ event: NSEvent) {
        guard let start = panStart, let origin = panOrigin, let scroll = enclosingScrollView else { return }
        let location = event.locationInWindow
        scroll.contentView.scroll(to: CGPoint(x: origin.x - location.x + start.x, y: origin.y + location.y - start.y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    private func endPan() {
        panStart = nil; panOrigin = nil
        if pushedPanCursor { NSCursor.pop(); pushedPanCursor = false }
    }
    override func rightMouseDown(with event: NSEvent) { startPan(event) }
    override func rightMouseDragged(with event: NSEvent) { continuePan(event) }
    override func rightMouseUp(with event: NSEvent) { endPan() }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { super.keyDown(with: event); return }
        if event.keyCode == 49 { spaceHeld = true; window?.invalidateCursorRects(for: self); return }
        if event.keyCode == 53 {
            draft = nil; draftSource = nil; movingMarkup = nil; movingPreview = nil; movingOffset = .zero; dragStart = nil
            store.selectionRect = nil; store.selectedID = nil; needsDisplay = true; return
        }
        if event.keyCode == 51 || event.keyCode == 117 { store.deleteSelection(); return }
        if event.keyCode == 36 || event.keyCode == 76 { store.cropSelection(); return }
        if event.keyCode == 48 { store.copyColor(); return }
        if let key = event.charactersIgnoringModifiers?.lowercased(), let tool = EditorTool.allCases.first(where: { $0.shortcut == key }) { store.tool = tool; window?.invalidateCursorRects(for: self); return }
        super.keyDown(with: event)
    }
    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { spaceHeld = false; window?.invalidateCursorRects(for: self) }
        else { super.keyUp(with: event) }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])?.first as? URL else { return false }
        store.importFile(url); return true
    }
}
