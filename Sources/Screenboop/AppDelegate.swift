import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let store = AppStore()
    var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var hotKeys: GlobalHotKeys?
    private var subscriptions: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .aqua)
        buildMainMenu()
        buildStatusMenu()
        let frame = CGRect(x: 100, y: 100, width: 1320, height: 830)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Screenboop"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .white
        window.minSize = CGSize(width: 1080, height: 700)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: EditorView(store: store))
        window.setFrameAutosaveName("ScreenboopEditor")
        window.center()
        self.window = window
        store.showWindow = { [weak self] in self?.showEditor(nil) }
        store.$document.sink { [weak self] document in
            self?.window?.title = document.map { "\($0.title) — Screenboop" } ?? "Screenboop"
        }.store(in: &subscriptions)
        if let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let image = NSImage(contentsOf: icon) { NSApp.applicationIconImage = image }
        let hotKeys = GlobalHotKeys { [weak self] identifier in
            guard identifier >= 1, identifier <= CaptureMode.allCases.count else { return }
            self?.store.capture(CaptureMode.allCases[Int(identifier) - 1])
        }
        self.hotKeys = hotKeys
        if let warning = hotKeys.register() { store.status = warning }
        showEditor(nil)
        let args = Array(CommandLine.arguments.dropFirst())
        if let index = args.firstIndex(of: "--open"), args.indices.contains(index + 1) {
            store.importFile(URL(fileURLWithPath: args[index + 1]))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showEditor(nil); return true }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if let filename = filenames.first { store.importFile(URL(fileURLWithPath: filename)) }
        sender.reply(toOpenOrPrint: .success)
    }
    func applicationWillTerminate(_ notification: Notification) { hotKeys?.unregister(); store.cancelCapture() }

    @objc func showEditor(_ sender: Any?) {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func captureArea(_ sender: Any?) { store.capture(.area) }
    @objc func captureWindow(_ sender: Any?) { store.capture(.window) }
    @objc func captureScreen(_ sender: Any?) { store.capture(.fullscreen) }
    @objc func captureDelayed(_ sender: Any?) { store.capture(.delayed) }
    @objc func captureScrolling(_ sender: Any?) { store.capture(.scrolling) }
    @objc func openImage(_ sender: Any?) { showEditor(nil); store.openImage() }
    @objc func pasteImage(_ sender: Any?) {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView { text.paste(sender) }
        else { showEditor(nil); store.pasteImage() }
    }
    @objc func copyImage(_ sender: Any?) {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView { text.copy(sender) }
        else { store.copyImage() }
    }
    @objc func exportPNG(_ sender: Any?) { store.exportImage() }
    @objc func exportJPEG(_ sender: Any?) { store.exportImage(jpeg: true) }
    @objc func undo(_ sender: Any?) {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView { text.undoManager?.undo() }
        else { store.undo() }
    }
    @objc func redo(_ sender: Any?) {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView { text.undoManager?.redo() }
        else { store.redo() }
    }
    @objc func selectAll(_ sender: Any?) {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView { text.selectAll(sender) }
        else if let document = store.document { store.selectionRect = CGRect(origin: .zero, size: document.size) }
    }
    @objc func recognize(_ sender: Any?) { store.recognizeText() }
    @objc func pin(_ sender: Any?) { store.pin() }
    @objc func resize(_ sender: Any?) { store.showResize = true }
    @objc func fit(_ sender: Any?) { store.zoomToFit() }
    @objc func actualSize(_ sender: Any?) { store.zoom = 1 }
    @objc func zoomIn(_ sender: Any?) { store.zoom = min(8, store.zoom * 1.25) }
    @objc func zoomOut(_ sender: Any?) { store.zoom = max(0.05, store.zoom / 1.25) }
    @objc func about(_ sender: Any?) { showEditor(nil); store.showAbout = true }
    @objc func example(_ sender: Any?) { showEditor(nil); store.newExample() }
    @objc func history(_ sender: Any?) { store.revealHistory() }
    @objc func privacy(_ sender: Any?) { store.openPrivacySettings() }
    @objc func terminate(_ sender: Any?) { NSApp.terminate(sender) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let requiresImage: [Selector] = [#selector(exportPNG(_:)), #selector(exportJPEG(_:)), #selector(recognize(_:)), #selector(pin(_:)), #selector(resize(_:)), #selector(fit(_:)), #selector(actualSize(_:)), #selector(zoomIn(_:)), #selector(zoomOut(_:))]
        if let action = menuItem.action, requiresImage.contains(action) { return store.document != nil && !store.isBusy }
        if menuItem.action == #selector(undo(_:)) { return (NSApp.keyWindow?.firstResponder as? NSTextView)?.undoManager?.canUndo ?? store.canUndo }
        if menuItem.action == #selector(redo(_:)) { return (NSApp.keyWindow?.firstResponder as? NSTextView)?.undoManager?.canRedo ?? store.canRedo }
        return true
    }

    private func item(_ title: String, _ selector: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        item.keyEquivalentModifierMask = modifiers
        return item
    }
    private func submenu(_ title: String, into root: NSMenu) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title); item.submenu = menu; root.addItem(item); return menu
    }
    private func addCaptureItems(to menu: NSMenu) {
        let selectors: [Selector] = [#selector(captureArea(_:)), #selector(captureWindow(_:)), #selector(captureScreen(_:)), #selector(captureDelayed(_:)), #selector(captureScrolling(_:))]
        for (index, mode) in CaptureMode.allCases.enumerated() {
            menu.addItem(item(mode.title, selectors[index], key: String(index + 1), modifiers: [.control, .option]))
        }
    }
    private func buildMainMenu() {
        let root = NSMenu()
        let application = submenu("Screenboop", into: root)
        application.addItem(item("About Screenboop & shortcuts", #selector(about(_:))))
        application.addItem(.separator())
        let hide = NSMenuItem(title: "Hide Screenboop", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        application.addItem(hide)
        application.addItem(item("Quit Screenboop", #selector(terminate(_:)), key: "q"))
        let file = submenu("File", into: root)
        file.addItem(item("Open image…", #selector(openImage(_:)), key: "o"))
        file.addItem(item("Open example image", #selector(example(_:))))
        file.addItem(.separator())
        file.addItem(item("Export PNG…", #selector(exportPNG(_:)), key: "s"))
        file.addItem(item("Export JPEG…", #selector(exportJPEG(_:)), key: "s", modifiers: [.command, .shift]))
        file.addItem(item("Show capture history", #selector(history(_:))))
        file.addItem(.separator())
        file.addItem(NSMenuItem(title: "Close window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        let edit = submenu("Edit", into: root)
        edit.addItem(item("Undo", #selector(undo(_:)), key: "z"))
        edit.addItem(item("Redo", #selector(redo(_:)), key: "z", modifiers: [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Copy image / text", #selector(copyImage(_:)), key: "c"))
        edit.addItem(item("Paste image / text", #selector(pasteImage(_:)), key: "v"))
        edit.addItem(item("Select all", #selector(selectAll(_:)), key: "a"))
        let capture = submenu("Capture", into: root)
        addCaptureItems(to: capture)
        let image = submenu("Image", into: root)
        image.addItem(item("Read text & QR codes", #selector(recognize(_:)), key: "r", modifiers: [.command, .shift]))
        image.addItem(item("Pin floating reference", #selector(pin(_:)), key: "p", modifiers: [.command, .shift]))
        image.addItem(item("Resize…", #selector(resize(_:))))
        let view = submenu("View", into: root)
        view.addItem(item("Zoom to fit", #selector(fit(_:)), key: "1"))
        view.addItem(item("Actual pixels", #selector(actualSize(_:)), key: "0"))
        view.addItem(item("Zoom in", #selector(zoomIn(_:)), key: "+"))
        view.addItem(item("Zoom out", #selector(zoomOut(_:)), key: "-"))
        let help = submenu("Help", into: root)
        help.addItem(item("Screenboop shortcuts & privacy", #selector(about(_:))))
        help.addItem(item("Screen Recording settings", #selector(privacy(_:))))
        NSApp.mainMenu = root
    }
    private func buildStatusMenu() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Screenboop")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = "Screenboop — capture, annotate, share"
        let menu = NSMenu()
        menu.addItem(item("Open Screenboop", #selector(showEditor(_:))))
        menu.addItem(.separator())
        addCaptureItems(to: menu)
        menu.addItem(.separator())
        menu.addItem(item("Open image…", #selector(openImage(_:))))
        menu.addItem(item("Paste image", #selector(pasteImage(_:))))
        menu.addItem(item("Show capture history", #selector(history(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit Screenboop", #selector(terminate(_:))))
        statusItem.menu = menu
        self.statusItem = statusItem
    }
}
