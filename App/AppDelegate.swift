import AppKit
import Observation
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var panel: NSPanel!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var sigterm: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.contentView = NSHostingView(rootView: PillView(model: model))

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Notchverse")
        let menu = NSMenu()
        let lyricsItem = menu.addItem(withTitle: "Show Lyrics", action: #selector(toggleLyrics(_:)), keyEquivalent: "l")
        lyricsItem.target = self
        lyricsItem.state = model.showLyrics ? .on : .off
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Notchverse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
        observe()
        // The panel is a fixed, mostly transparent canvas; only the black shape takes the mouse.
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse() }
        }
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] e in
            MainActor.assumeIsolated { self?.trackMouse() }
            return e
        }
        // `kill` / logout: quit normally so the adapter process is stopped too.
        signal(SIGTERM, SIG_IGN)
        sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm?.setEventHandler { NSApp.terminate(nil) }
        sigterm?.resume()
        Task { await model.start() }
    }

    func applicationWillTerminate(_ notification: Notification) { model.stop() }

    /// Re-run layout whenever anything it reads on the model changes.
    private func observe() {
        withObservationTracking { layout() } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.observe() } }
        }
    }

    /// Screen rect of the black shape as it is now (compact or expanded).
    private var shapeRect: NSRect {
        let s = model.expanded ? model.expandedSize : model.compactSize
        let f = panel.frame
        return NSRect(x: f.midX - s.width / 2, y: f.maxY - s.height, width: s.width, height: s.height)
    }

    private func mouseOnShape() -> Bool { panel.isVisible && NSMouseInRect(NSEvent.mouseLocation, shapeRect, false) }

    /// Hover to open; collapse once the cursor has been off the shape for 0.25 s.
    /// Outside the shape the panel ignores the mouse, so clicks reach the windows below.
    private func trackMouse() {
        let inside = mouseOnShape()
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        if inside {
            if !model.expanded { model.expanded = true }
        } else if model.expanded {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                if !self.mouseOnShape() { self.model.expanded = false }
            }
        }
    }

    private func layout() {
        if model.compactKind == .idle, model.idleSlots.allSatisfy { $0 == .none }, !model.expanded {
            panel.orderOut(nil)
            return
        }
        let mouseScreen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
        guard let screen = (model.screenChoice == "mouse" ? mouseScreen : nil) ?? NSScreen.screens.first else { return }

        // Real notch: its size from the screen. No notch: a virtual one the size of a MacBook Pro notch (≈200×32 pt).
        let realNotch = screen.safeAreaInsets.top
        let notchWidth = realNotch > 0
            ? screen.frame.width - (screen.auxiliaryTopLeftArea?.width ?? 0) - (screen.auxiliaryTopRightArea?.width ?? 0) : 200
        let attached = model.displayMode != "floating"
        let inset = attached ? realNotch : 0 // real notch: content sits below the camera
        if model.notchInset != inset { model.notchInset = inset }
        if model.attached != attached { model.attached = attached }

        let compactHeight: CGFloat = !attached ? 38 : realNotch > 0 ? 28 : 32
        let compactWidth = max(notchWidth + 100, model.compactKind == .music ? 360 : 300)
        let compact = CGSize(width: compactWidth, height: compactHeight + inset)
        let expanded = CGSize(width: 460, height: 320 + inset)
        if model.compactSize != compact { model.compactSize = compact }
        if model.expandedSize != expanded { model.expandedSize = expanded }
        // Fixed canvas big enough for both states; SwiftUI animates the shape inside it.
        let size = CGSize(width: max(compact.width, expanded.width) + 40, height: expanded.height + 20)
        let top = attached ? screen.frame.maxY : screen.visibleFrame.maxY - 8
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height)

        let behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.collectionBehavior = model.hideInFullscreen ? behavior : behavior.union(.fullScreenAuxiliary)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        panel.orderFrontRegardless()
    }

    @objc private func toggleLyrics(_ item: NSMenuItem) {
        model.showLyrics.toggle()
        item.state = model.showLyrics ? .on : .off
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            w.title = "Notchverse Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
