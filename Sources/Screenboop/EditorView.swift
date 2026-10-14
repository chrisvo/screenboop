import AppKit
import SwiftUI

private let ink = Color(red: 0.14, green: 0.15, blue: 0.21)
private let accent = Color(red: 0.40, green: 0.34, blue: 0.95)
private let muted = Color(red: 0.49, green: 0.50, blue: 0.56)

struct EditorView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 210)
            Divider()
            VStack(spacing: 0) {
                header
                Divider()
                if store.document != nil {
                    toolShelf
                    Divider()
                    HStack(spacing: 0) {
                        CanvasBridge(store: store)
                        Divider()
                        inspector.frame(width: 208)
                    }
                } else { welcome }
                Divider()
                footer
            }
        }
        .background(Color.white)
        .foregroundStyle(ink)
        .tint(accent)
        .preferredColorScheme(.light)
        .sheet(isPresented: $store.showRecognition) { recognitionSheet }
        .sheet(isPresented: $store.showResize) { ResizeSheet(store: store) }
        .sheet(isPresented: $store.showAbout) { aboutSheet }
        .alert("screenboop", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
            Button("Screen recording settings") { store.errorMessage = nil; store.openPrivacySettings() }
        } message: { Text(store.errorMessage ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(accent.gradient).frame(width: 35, height: 35)
                    Image(systemName: "viewfinder").font(.system(size: 21, weight: .semibold)).foregroundStyle(.white)
                    Circle().fill(Color(red: 0.78, green: 0.98, blue: 0.58)).frame(width: 7, height: 7).offset(x: 7, y: -7)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("screenboop").font(.system(size: 19, weight: .bold, design: .rounded)).tracking(-0.6)
                    Text("A LITTLE MORE CLARITY").font(.system(size: 7.5, weight: .semibold)).tracking(1.25).foregroundStyle(muted)
                }
            }.padding(.top, 22).padding(.bottom, 27)
            sectionTitle("CAPTURE")
            captureButton(.area, icon: "viewfinder", shortcut: "⌃⌥1", primary: true)
            captureButton(.window, icon: "macwindow", shortcut: "⌃⌥2")
            captureButton(.fullscreen, icon: "display", shortcut: "⌃⌥3")
            captureButton(.delayed, icon: "timer", shortcut: "⌃⌥4")
            captureButton(.scrolling, icon: "arrow.down.to.line", shortcut: "⌃⌥5")
            Divider().padding(.vertical, 19)
            HStack {
                sectionTitle("RECENT CAPTURES")
                Spacer()
                Button { store.revealHistory() } label: { Image(systemName: "folder").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(muted).help("Open capture history folder")
            }.padding(.bottom, 8)
            if store.history.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Your next good idea\nstarts with a capture.").font(.system(size: 12)).foregroundStyle(muted).lineSpacing(4)
                    Text("Saved locally, never uploaded.").font(.system(size: 10)).foregroundStyle(muted.opacity(0.8))
                }.padding(.top, 7)
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(store.history.prefix(40)) { item in
                            Button { store.importFile(item.url) } label: {
                                HStack(spacing: 9) {
                                    HistoryThumbnail(url: item.url)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.date, style: .time).font(.system(size: 11, weight: .medium))
                                        Text("\(item.width) × \(item.height)").font(.system(size: 9, design: .monospaced)).foregroundStyle(muted)
                                    }
                                    Spacer(minLength: 0)
                                }.padding(7).background(.white).clipShape(RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain).help(item.url.lastPathComponent)
                        }
                    }
                }
                Button("Clear history…") { store.clearHistory() }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(muted).padding(.top, 8)
            }
            Spacer(minLength: 18)
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) { Circle().fill(Color(red: 0.26, green: 0.70, blue: 0.49)).frame(width: 5, height: 5); Text("100% on your Mac").font(.system(size: 11, weight: .medium)) }
                Text("No account. No uploads.\nJust you and your pixels.").font(.system(size: 10)).foregroundStyle(muted).lineSpacing(3)
                Button { store.showAbout = true } label: { Label("Shortcuts & about", systemImage: "keyboard").font(.system(size: 10)) }.buttonStyle(.plain).foregroundStyle(muted).padding(.top, 5)
            }
            .padding(13).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.7)).clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 17)
        .background(Color(red: 0.968, green: 0.968, blue: 0.982))
    }

    private func captureButton(_ mode: CaptureMode, icon: String, shortcut: String, primary: Bool = false) -> some View {
        Button { store.capture(mode) } label: {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 13)).frame(width: 17)
                Text(captureLabel(mode)).font(.system(size: 12, weight: primary ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 2)
                Text(shortcut).font(.system(size: 10, design: .monospaced)).foregroundStyle(primary ? accent.opacity(0.7) : muted.opacity(0.8))
            }
            .foregroundStyle(primary ? accent : ink.opacity(0.8))
            .padding(.horizontal, 10).frame(height: 36)
            .background(primary ? accent.opacity(0.10) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).disabled(store.isBusy).padding(.vertical, 2)
    }

    private func captureLabel(_ mode: CaptureMode) -> String {
        switch mode {
        case .area: "Area"
        case .window: "Window"
        case .fullscreen: "Screen"
        case .delayed: "5-second timer"
        case .scrolling: "Scrolling"
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(store.document?.title ?? "Your pixel playground").font(.system(size: 15, weight: .semibold)).lineLimit(1)
                if let document = store.document {
                    HStack(spacing: 6) {
                        Text("\(document.image.width) × \(document.image.height) px").font(.system(size: 10, design: .monospaced))
                        Text("·")
                        Text("\(document.annotations.count) annotations").font(.system(size: 10))
                    }.foregroundStyle(muted)
                } else { Text("Capture something. Make your point.").font(.system(size: 11)).foregroundStyle(muted) }
            }
            Spacer(minLength: 12)
            Button { store.openImage() } label: { Label("Open", systemImage: "folder").font(.system(size: 11, weight: .medium)) }.buttonStyle(.borderless)
                .help("Open image · ⌘O")
            Button { store.pasteImage() } label: { Image(systemName: "document.on.clipboard").font(.system(size: 13)) }.buttonStyle(.borderless).help("Paste image · ⌘V")
            if store.document != nil {
                Divider().frame(height: 25)
                Button { store.pin() } label: { Image(systemName: "pin").font(.system(size: 13)) }.buttonStyle(.borderless).help("Pin as floating reference")
                Button { store.copyImage() } label: { Label("Copy", systemImage: "square.on.square").font(.system(size: 11, weight: .medium)) }.buttonStyle(.bordered).controlSize(.large).help("Copy flattened PNG · ⌘C")
                HStack(spacing: 5) {
                    Button { store.exportImage() } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 13).frame(height: 33)
                            .background(accent).clipShape(RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).help("Export PNG · ⌘S")
                    Menu {
                        Button("Export PNG…") { store.exportImage() }
                        Button("Export JPEG…") { store.exportImage(jpeg: true) }
                    } label: { Image(systemName: "chevron.down").font(.system(size: 10)) }
                    .menuStyle(.borderlessButton).frame(width: 16).help("Choose export format")
                }
            }
        }.padding(.horizontal, 23).frame(height: 74)
    }

    private var toolShelf: some View {
        HStack(spacing: 3) {
            ForEach(EditorTool.allCases) { tool in
                Button { store.tool = tool; store.selectedID = nil } label: {
                    Image(systemName: tool.symbol).font(.system(size: 14, weight: .medium))
                        .frame(width: 31, height: 32)
                        .foregroundStyle(store.tool == tool ? accent : ink.opacity(0.62))
                        .background(store.tool == tool ? accent.opacity(0.12) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).help("\(tool.title) · \(tool.shortcut.uppercased())")
                    .accessibilityLabel(tool.title)
            }
            Spacer(minLength: 2)
            Divider().frame(height: 21).padding(.horizontal, 6)
            Button { store.undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 24, height: 30) }.buttonStyle(.plain).disabled(!store.canUndo).help("Undo · ⌘Z")
            Button { store.redo() } label: { Image(systemName: "arrow.uturn.forward").frame(width: 24, height: 30) }.buttonStyle(.plain).disabled(!store.canRedo).help("Redo · ⇧⌘Z")
        }.padding(.horizontal, 16).frame(height: 50)
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 19) {
                VStack(alignment: .leading, spacing: 9) {
                    sectionTitle("\(store.tool.title.uppercased()) TOOL")
                    Text(toolHelp).font(.system(size: 11)).foregroundStyle(muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                VStack(alignment: .leading, spacing: 11) {
                    HStack {
                        sectionTitle("COLOR")
                        Spacer()
                        ColorPicker("Annotation color", selection: Binding(get: { Color(nsColor: store.color) }, set: { store.color = NSColor($0) }), supportsOpacity: false).labelsHidden().frame(width: 24)
                    }
                    HStack(spacing: 7) {
                        ForEach(Array(palette.enumerated()), id: \.offset) { _, color in
                            Button { store.color = color } label: {
                                Circle().fill(Color(nsColor: color)).frame(width: 21, height: 21)
                                    .overlay(Circle().strokeBorder(.white, lineWidth: 2).padding(3).opacity(store.color == color ? 1 : 0))
                            }.buttonStyle(.plain)
                        }
                    }
                    HStack { Text("Stroke").font(.system(size: 11)); Spacer(); Text("\(Int(store.lineWidth)) px").font(.system(size: 10, design: .monospaced)).foregroundStyle(muted) }
                    Slider(value: $store.lineWidth, in: 2...16, step: 1).controlSize(.small)
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("FINISHING TOUCHES")
                    HStack(spacing: 7) {
                        ForEach(BackdropStyle.allCases) { style in
                            Button { store.changeBackdrop(style: style) } label: {
                                RoundedRectangle(cornerRadius: 6).fill(backdropGradient(style)).frame(width: 34, height: 30)
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(store.document?.backdrop.style == style ? accent : .gray.opacity(0.25), lineWidth: store.document?.backdrop.style == style ? 2 : 0.5))
                                    .overlay { if style == .none { Image(systemName: "slash.circle").font(.system(size: 13)).foregroundStyle(muted) } }
                            }.buttonStyle(.plain).help("\(style.title) backdrop")
                        }
                    }
                    if let backdrop = store.document?.backdrop, backdrop.style != .none {
                        Picker("Padding", selection: Binding(get: { Int(backdrop.padding) }, set: { store.changeBackdrop(padding: CGFloat($0)) })) {
                            Text("32 px").tag(32); Text("64 px").tag(64); Text("96 px").tag(96)
                        }.font(.system(size: 11))
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 11) {
                    sectionTitle("IMAGE ACTIONS")
                    actionRow("Read text & QR", symbol: "text.viewfinder") { store.recognizeText() }
                    actionRow("Resize image", symbol: "arrow.up.left.and.arrow.down.right") { store.showResize = true }
                    Menu {
                        Button("Stack images vertically…") { store.combineImages(vertically: true) }
                        Button("Join images horizontally…") { store.combineImages(vertically: false) }
                    } label: { Label("Combine images", systemImage: "square.stack.3d.up").font(.system(size: 11)) }.menuStyle(.borderlessButton)
                    if store.selectionRect != nil { actionRow("Crop selection ↵", symbol: "crop") { store.cropSelection() } }
                    if store.selectedID != nil { actionRow("Delete annotation", symbol: "trash") { store.deleteSelection() } }
                }
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    sectionTitle("PIXEL INSPECTOR")
                    HStack {
                        RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: colorFromHex(store.hoverHex))).frame(width: 27, height: 27).overlay(RoundedRectangle(cornerRadius: 5).stroke(.black.opacity(0.1), lineWidth: 1))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(store.hoverHex).font(.system(size: 11, weight: .medium, design: .monospaced))
                            Text("Tab to copy color").font(.system(size: 9)).foregroundStyle(muted)
                        }
                    }
                    Text("Move over the image to sample its original pixels.").font(.system(size: 10)).foregroundStyle(muted).lineSpacing(3)
                }
                Spacer(minLength: 10)
                Label("Pixelation is not secure redaction. Use Redact for private content.", systemImage: "lock.shield")
                    .font(.system(size: 9)).foregroundStyle(muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }.padding(17)
        }.background(Color.white)
    }

    private var toolHelp: String {
        switch store.tool {
        case .select: "Click a mark to select it, then drag to move. Drag empty space to select a crop or OCR region."
        case .crop: "Drag the region to keep, then press Return. Undo restores the complete image."
        case .text: "Click to place text. Choose a color and stroke size before placing it."
        case .number: "Click to place sequential numbered callouts."
        case .blur: "Drag to pixelate a region. This obscures detail but is not secure redaction."
        case .redact: "Drag to cover private content with an opaque mask. Exports flatten the mask into pixels."
        case .ruler: "Drag between two points to mark their distance in physical image pixels."
        case .magnifier: "Drag a circular lens to magnify its contents 2×. Click for a default lens."
        case .pen: "Draw freely. A single click makes a dot. Space-drag or right-drag to pan."
        case .rectangle, .ellipse: "Drag to draw. Hold Shift to keep the shape square."
        default: "Drag on your image to annotate. Use V to select and move marks; Delete removes a selection."
        }
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                Circle().fill(accent.opacity(0.045)).frame(width: 160, height: 160)
                Circle().fill(accent.opacity(0.07)).frame(width: 110, height: 110)
                Image(systemName: "viewfinder").font(.system(size: 49, weight: .light)).foregroundStyle(accent)
                Circle().fill(Color(red: 0.59, green: 0.84, blue: 0.58)).frame(width: 17, height: 17).offset(x: 29, y: -27)
            }.padding(.bottom, 20)
            Text("A screenshot. A little more useful.").font(.system(size: 27, weight: .semibold, design: .rounded)).tracking(-0.8)
            Text("Capture the moment, mark what matters, and send it on.\nYour screenshots and text stay right here on your Mac.")
                .font(.system(size: 13)).foregroundStyle(muted).multilineTextAlignment(.center).lineSpacing(6).padding(.top, 12)
            HStack(spacing: 10) {
                Button { store.capture(.area) } label: { Label("Capture an area", systemImage: "viewfinder").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 12).padding(.vertical, 6) }.buttonStyle(.borderedProminent).controlSize(.large)
                Button { store.openImage() } label: { Label("Open an image", systemImage: "folder").font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 6) }.buttonStyle(.bordered).controlSize(.large)
            }.padding(.top, 25).disabled(store.isBusy)
            Button("Try it with an example image →") { store.newExample() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(accent).padding(.top, 17)
            HStack(spacing: 27) {
                welcomeFeature("Mark it up", icon: "pencil.tip")
                welcomeFeature("Hide the private bits", icon: "lock.shield")
                welcomeFeature("Grab the words", icon: "text.viewfinder")
            }.padding(.top, 45)
            Spacer()
            if !CGPreflightScreenCaptureAccess() {
                HStack(spacing: 9) {
                    Image(systemName: "info.circle").foregroundStyle(accent)
                    Text("First capture? macOS will ask for Screen Recording permission.").font(.system(size: 10)).foregroundStyle(muted)
                    Button("Settings") { store.openPrivacySettings() }.font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(accent)
                }.padding(13).background(accent.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 9)).padding(.bottom, 28)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(red: 0.992, green: 0.992, blue: 0.998))
    }

    private func welcomeFeature(_ title: String, icon: String) -> some View {
        HStack(spacing: 7) { Image(systemName: icon).font(.system(size: 12)).foregroundStyle(accent.opacity(0.75)); Text(title).font(.system(size: 11)).foregroundStyle(muted) }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if store.isBusy { ProgressView().controlSize(.mini); Button("Cancel") { store.cancelCapture() }.buttonStyle(.plain).font(.system(size: 10)) }
            else { Image(systemName: "checkmark.circle").font(.system(size: 10)).foregroundStyle(Color.green.opacity(0.7)) }
            Text(store.status).font(.system(size: 10)).foregroundStyle(muted).lineLimit(1)
            Spacer(minLength: 4)
            if let point = store.hoverPosition { Text("\(Int(point.x)), \(Int(point.y))").font(.system(size: 9, design: .monospaced)).foregroundStyle(muted) }
            if store.document != nil {
                Button { store.zoomToFit() } label: { Text("Fit").font(.system(size: 10)) }.buttonStyle(.plain).foregroundStyle(muted)
                Button { store.zoom = max(0.05, store.zoom / 1.25) } label: { Image(systemName: "minus").font(.system(size: 10)).frame(width: 17) }.buttonStyle(.plain)
                Text("\(Int(store.zoom * 100))%").font(.system(size: 10, design: .monospaced)).frame(width: 38)
                Button { store.zoom = min(8, store.zoom * 1.25) } label: { Image(systemName: "plus").font(.system(size: 10)).frame(width: 17) }.buttonStyle(.plain)
            }
        }.padding(.horizontal, 17).frame(height: 34)
    }

    private var recognitionSheet: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack { Label("Text & QR recognition", systemImage: "text.viewfinder").font(.system(size: 18, weight: .semibold)); Spacer(); Text("ON-DEVICE").font(.system(size: 9, weight: .bold)).foregroundStyle(accent).padding(7).background(accent.opacity(0.08)).clipShape(Capsule()) }
            Text("Recognized locally with Apple Vision. Review or edit before copying. QR payloads are plain text, never opened automatically.").font(.system(size: 12)).foregroundStyle(muted)
            TextEditor(text: $store.recognizedText).font(.system(size: 13, design: .monospaced)).padding(8).background(Color.gray.opacity(0.04)).overlay(RoundedRectangle(cornerRadius: 8).stroke(.gray.opacity(0.2))).frame(minHeight: 220)
            HStack { Button("Close") { store.showRecognition = false }; Spacer(); Button("Copy text") { store.copyRecognizedText() }.buttonStyle(.borderedProminent).disabled(store.recognizedText.isEmpty) }
        }.padding(26).frame(width: 600, height: 400)
    }

    private var aboutSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("screenboop").font(.system(size: 25, weight: .bold, design: .rounded))
            Text("An original, local-only macOS screenshot utility. Inspired by Shottr’s workflows, not its code or artwork.").font(.system(size: 12)).foregroundStyle(muted)
            Divider()
            Text("CAPTURE ANYWHERE").font(.system(size: 10, weight: .semibold)).foregroundStyle(muted)
            Text("⌃⌥1  Area     ⌃⌥2  Window     ⌃⌥3  Screen\n⌃⌥4  5-second timer     ⌃⌥5  Scrolling capture").font(.system(size: 12, design: .monospaced)).lineSpacing(8)
            Divider()
            Text("EDITOR SHORTCUTS").font(.system(size: 10, weight: .semibold)).foregroundStyle(muted)
            Text("⌘O Open   ⌘V Paste   ⌘C Copy   ⌘S Export\n⌘Z Undo   ⇧⌘Z Redo   ⌘0 Actual size   ⌘1 Fit\nV Select   A Arrow   R Rectangle   T Text   B Pixelate\nX Redact   M Measure   Tab Copy color\nReturn Crop selection   Delete Remove mark\nSpace-drag or right-drag Pan").font(.system(size: 11, design: .monospaced)).lineSpacing(7)
            Text("Capture history stores original screenshots locally. Use Clear history to remove sensitive originals. Pixelation is not secure redaction.").font(.system(size: 11)).foregroundStyle(muted)
            HStack { Spacer(); Button("Got it") { store.showAbout = false }.buttonStyle(.borderedProminent) }
        }.padding(28).frame(width: 540)
    }

    private func sectionTitle(_ text: String) -> some View { Text(text).font(.system(size: 9, weight: .semibold)).tracking(1.1).foregroundStyle(muted) }
    private func actionRow(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol).font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain).disabled(store.isBusy)
    }
    private var palette: [NSColor] { [.init(srgbRed: 0.40, green: 0.34, blue: 0.95, alpha: 1), .systemRed, .systemOrange, .systemGreen, .systemBlue, .black] }
    private func backdropGradient(_ style: BackdropStyle) -> LinearGradient {
        let colors: [Color]
        switch style {
        case .none: colors = [.white, .white]
        case .aurora: colors = [Color(red: 0.50, green: 0.34, blue: 0.95), Color(red: 0.37, green: 0.77, blue: 0.86)]
        case .midnight: colors = [Color(red: 0.09, green: 0.11, blue: 0.25), Color(red: 0.29, green: 0.28, blue: 0.50)]
        case .peach: colors = [Color(red: 1, green: 0.73, blue: 0.64), Color(red: 1, green: 0.89, blue: 0.73)]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    private func colorFromHex(_ text: String) -> NSColor {
        guard let value = UInt32(text.replacingOccurrences(of: "#", with: ""), radix: 16) else { return .clear }
        return NSColor(srgbRed: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, alpha: 1)
    }
}

private struct HistoryThumbnail: View {
    let url: URL
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "photo").foregroundStyle(.gray.opacity(0.4)) }
        }.frame(width: 42, height: 31).background(Color.gray.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: 4))
        .task { image = await Task.detached { ImageFiles.thumbnail(url) }.value }
    }
}

private struct ResizeSheet: View {
    @ObservedObject var store: AppStore
    @State private var width = ""
    @State private var height = ""
    @State private var keepRatio = true
    @State private var adjusting = false
    private var ratio: Double { guard let image = store.document?.image else { return 1 }; return Double(image.width) / Double(image.height) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Resize image").font(.system(size: 20, weight: .semibold))
            Text("Dimensions are physical pixels. Resizing flattens annotations; Undo restores the editable image.").font(.system(size: 12)).foregroundStyle(muted)
            HStack {
                VStack(alignment: .leading) { Text("Width").font(.system(size: 11)); TextField("Pixels", text: $width).textFieldStyle(.roundedBorder) }
                Text("×").foregroundStyle(muted)
                VStack(alignment: .leading) { Text("Height").font(.system(size: 11)); TextField("Pixels", text: $height).textFieldStyle(.roundedBorder) }
            }
            Toggle("Keep aspect ratio", isOn: $keepRatio)
            HStack { Button("Cancel") { store.showResize = false }; Spacer(); Button("Resize") { if let w = Int(width), let h = Int(height) { store.resize(width: w, height: h) } }.buttonStyle(.borderedProminent).disabled(Int(width).map { $0 > 0 && $0 <= 32768 } != true || Int(height).map { $0 > 0 && $0 <= 32768 } != true) }
        }.padding(27).frame(width: 430)
        .onAppear { width = String(store.document?.image.width ?? 0); height = String(store.document?.image.height ?? 0) }
        .onChange(of: width) { _, value in
            guard keepRatio, !adjusting, let number = Double(value), number.isFinite, number > 0, number <= 32768 else { return }
            let target = String(max(1, Int((number / ratio).rounded())))
            if target != height { adjusting = true; height = target; DispatchQueue.main.async { adjusting = false } }
        }
        .onChange(of: height) { _, value in
            guard keepRatio, !adjusting, let number = Double(value), number.isFinite, number > 0, number <= 32768 else { return }
            let target = String(max(1, Int((number * ratio).rounded())))
            if target != width { adjusting = true; width = target; DispatchQueue.main.async { adjusting = false } }
        }
    }
}
