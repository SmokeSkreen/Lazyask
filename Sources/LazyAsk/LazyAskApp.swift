import AppKit
import Combine
import SwiftUI

@main
enum LazyAskMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = AppModel()
    private var mainWindow: NSWindow!
    private var overlay: AnswerPanel!
    private var statusItem: NSStatusItem!
    private var subscription: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        mainWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        mainWindow.title = "Lazy Ask"
        mainWindow.isReleasedWhenClosed = false
        mainWindow.contentView = NSHostingView(rootView: MainView(model: model))
        mainWindow.center()
        mainWindow.minSize = NSSize(width: 760, height: 540)

        overlay = AnswerPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 270),
                              styleMask: [.borderless, .resizable, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        overlay.contentView = NSHostingView(rootView: OverlayView(model: model))
        overlay.isReleasedWhenClosed = false
        overlay.isFloatingPanel = true
        overlay.level = .floating
        overlay.hidesOnDeactivate = false
        overlay.isMovableByWindowBackground = true
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        overlay.sharingType = .none
        overlay.minSize = NSSize(width: 340, height: 210)
        overlay.hasShadow = true
        overlay.title = "Lazy Ask Answer"
        positionOverlay()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Lazy Ask")
        statusItem.button?.toolTip = "Lazy Ask"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        subscription = model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.statusItem.button?.image = NSImage(systemSymbolName: self.model.state.active ? "waveform.circle.fill" : "waveform.circle",
                                                       accessibilityDescription: "Lazy Ask: " + self.model.state.label)
            }
        }
        model.onShowOverlay = { [weak self] in self?.overlay.orderFrontRegardless() }
        model.onHideOverlay = { [weak self] in self?.overlay.orderOut(nil) }
        model.onOpenMain = { [weak self] in self?.showMain() }
        showMain()
        if CommandLine.arguments.contains("--demo") { model.runDemo() }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: model.state.label, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        addItem("Lazy Meetings", action: #selector(home), to: menu, enabled: !model.isNavigating)
        addItem(model.state == .starting ? "Cancel connection" : model.state.active ? "Stop listening" : "Start listening",
                action: #selector(toggle), to: menu, enabled: !model.isHome && !model.isNavigating && model.state != .stopping)
        addItem("Answer latest question", action: #selector(askLatest), to: menu, enabled: !model.isHome)
        addItem("Show answer", action: #selector(showAnswer), to: menu, enabled: !model.isHome)
        menu.addItem(.separator())
        addItem("Open Lazy Ask", action: #selector(showMain), to: menu)
        addItem("Settings...", action: #selector(settings), to: menu)
        addItem("Run demo", action: #selector(demo), to: menu, enabled: model.state == .idle)
        menu.addItem(.separator())
        addItem("Quit Lazy Ask", action: #selector(quit), to: menu)
    }

    private func addItem(_ title: String, action: Selector, to menu: NSMenu, enabled: Bool = true) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
    }

    private func positionOverlay() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        overlay.setFrameOrigin(NSPoint(x: visible.maxX - overlay.frame.width - 24, y: visible.minY + 24))
    }

    private func installMainMenu() {
        let root = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Lazy Ask")
        let settings = NSMenuItem(title: "Settings...", action: #selector(settings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Lazy Ask", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        root.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        root.addItem(editItem)
        NSApplication.shared.mainMenu = root
    }

    @objc private func toggle() { model.toggleListening() }
    @objc private func home() { showMain(); Task { await model.goHome() } }
    @objc private func askLatest() { model.askLatest() }
    @objc private func showAnswer() { overlay.orderFrontRegardless() }
    @objc private func settings() { showMain(); model.showSettings = true }
    @objc private func demo() { showMain(); model.runDemo() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
    @objc private func showMain() { mainWindow.makeKeyAndOrderFront(nil); NSApplication.shared.activate() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMain()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await model.stopListening()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

final class AnswerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
