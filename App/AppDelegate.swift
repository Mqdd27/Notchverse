import AppKit
import Observation
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var panel: NSPanel!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?

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
        Task { await model.start() }
    }

    func applicationWillTerminate(_ notification: Notification) { model.stop() }

    /// Re-run layout whenever anything it reads on the model changes.
    private func observe() {
        withObservationTracking { layout() } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.observe() } }
        }
    }

    private func layout() {
        guard model.state != nil else { panel.orderOut(nil); return }
        let mouseScreen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
        guard let screen = (model.screenChoice == "mouse" ? mouseScreen : nil) ?? NSScreen.screens.first else { return }

        let notchHeight = screen.safeAreaInsets.top
        let notch = model.displayMode == "notch" || (model.displayMode == "auto" && notchHeight > 0)
        let inset = notch ? max(notchHeight, NSStatusBar.system.thickness) : 0
        if model.notchInset != inset { model.notchInset = inset }

        let size = !model.expanded ? NSSize(width: 380, height: 38)
            : NSSize(width: 440, height: model.showLyrics || model.candidates != nil ? 290 : 110)
        let top = notch ? screen.frame.maxY : screen.visibleFrame.maxY - 8
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: top - size.height - inset,
                           width: size.width, height: size.height + inset)

        let behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.collectionBehavior = model.hideInFullscreen ? behavior : behavior.union(.fullScreenAuxiliary)
        if panel.isVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
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
