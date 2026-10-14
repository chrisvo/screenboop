import AppKit

// All document geometry is in image pixels, origin at the top-left.
enum EditorTool: String, CaseIterable, Identifiable {
    case select, crop, arrow, line, rectangle, ellipse, pen, highlighter, text, number, blur, redact, spotlight, ruler, magnifier
    var id: String { rawValue }
    var title: String {
        switch self {
        case .select: "Select"
        case .crop: "Crop"
        case .arrow: "Arrow"
        case .line: "Line"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .pen: "Pen"
        case .highlighter: "Highlight"
        case .text: "Text"
        case .number: "Counter"
        case .blur: "Pixelate"
        case .redact: "Redact"
        case .spotlight: "Spotlight"
        case .ruler: "Measure"
        case .magnifier: "Magnify"
        }
    }
    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .crop: "crop"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .text: "textformat"
        case .number: "1.circle"
        case .blur: "square.grid.3x3.fill"
        case .redact: "rectangle.fill"
        case .spotlight: "light.beacon.max"
        case .ruler: "ruler"
        case .magnifier: "plus.magnifyingglass"
        }
    }
    var shortcut: String {
        switch self {
        case .select: "v"
        case .crop: "c"
        case .arrow: "a"
        case .line: "l"
        case .rectangle: "r"
        case .ellipse: "o"
        case .pen: "p"
        case .highlighter: "h"
        case .text: "t"
        case .number: "n"
        case .blur: "b"
        case .redact: "x"
        case .spotlight: "s"
        case .ruler: "m"
        case .magnifier: "z"
        }
    }
}

struct Markup: Identifiable {
    var id = UUID()
    var tool: EditorTool
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint] = []
    var text: String = ""
    var color: NSColor = NSColor(srgbRed: 0.40, green: 0.34, blue: 0.95, alpha: 1)
    var lineWidth: CGFloat = 5
    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }
    mutating func translate(by delta: CGPoint) {
        start.x += delta.x; start.y += delta.y
        end.x += delta.x; end.y += delta.y
        points = points.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
    }
}

enum BackdropStyle: String, CaseIterable, Identifiable {
    case none, aurora, midnight, peach
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct Backdrop {
    var style: BackdropStyle = .none
    var padding: CGFloat = 64
    var cornerRadius: CGFloat = 20
    var shadow: Bool = true
}

struct ImageDocument {
    var image: CGImage
    var annotations: [Markup] = []
    var backdrop = Backdrop()
    var title: String = "Untitled capture"
    var size: CGSize { CGSize(width: image.width, height: image.height) }
}

enum CaptureMode: String, CaseIterable {
    case area, window, fullscreen, delayed, scrolling
    var title: String {
        switch self {
        case .area: "Capture area"
        case .window: "Capture window"
        case .fullscreen: "Capture screen"
        case .delayed: "Capture in 5 seconds"
        case .scrolling: "Scrolling capture"
        }
    }
}

struct HistoryItem: Identifiable {
    var id: String { url.lastPathComponent }
    let url: URL
    let date: Date
    let width: Int
    let height: Int
}

struct RecognizedContent {
    let text: String
    let codes: [String]
    var clipboardText: String { ([text] + codes).filter { !$0.isEmpty }.joined(separator: "\n") }
}

enum ScreenboopError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): text }
    }
}
