import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let state = AppState()
    private var item: NSStatusItem?
    private var settings: NSWindow?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item = status
        let menu = NSMenu()
        menu.delegate = self
        status.menu = menu
        state.onAppearanceChange = { [weak self] in self?.updateIcon() }
        updateIcon()
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification)
        observe(workspace, NSWorkspace.didWakeNotification)
        observe(.default, NSApplication.didChangeScreenParametersNotification)
        state.launch()
        if !UserDefaults.standard.bool(forKey: "didOpenSettings") || state.message != nil || !state.conflicts.isEmpty || state.needsPreviewAccess {
            UserDefaults.standard.set(true, forKey: "didOpenSettings")
            showSettings()
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            self?.state.spaceChanged()
        }
        observers.append((center, token))
    }

    private func updateIcon() {
        let symbol = state.enabled ? "rectangle.split.2x1.fill" : "rectangle.split.2x1"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "TouchTiles")
        image?.isTemplate = true
        item?.button?.image = image
        item?.button?.toolTip = state.enabled ? "TouchTiles · Tiling on" : "TouchTiles · Tiling off"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        func add(_ title: String, _ selector: Selector, enabled: Bool = true) {
            let row = menu.addItem(withTitle: title, action: selector, keyEquivalent: "")
            row.target = self
            row.isEnabled = enabled
        }
        add(state.enabled ? "Turn Tiling Off" : "Turn Tiling On", #selector(toggle))
        if state.enabled {
            menu.addItem(.separator())
            add("Float or Tile Window", #selector(floatWindow))
            add("Expand or Restore Window", #selector(fullscreenWindow))
        }
        menu.addItem(.separator())
        if state.message != nil || state.gestureIssue != nil || !state.conflicts.isEmpty
            || state.needsPreviewAccess || state.floatingPreviewIssue != nil {
            add("Review Setup…", #selector(showSettings))
        }
        add("Settings…", #selector(showSettings))
        add("Quit TouchTiles", #selector(quit))
    }

    @objc private func toggle() {
        state.setEnabled(!state.enabled)
        if state.access, state.message != nil || state.gestureIssue != nil { showSettings() }
    }

    @objc private func floatWindow() { state.perform(.float) }
    @objc private func fullscreenWindow() { state.perform(.fullscreen) }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc func showSettings() {
        if settings == nil {
            let controller = NSHostingController(rootView: SettingsView(state: state))
            let window = NSWindow(contentViewController: controller)
            window.title = "TouchTiles Settings"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.level = .floating
            window.hidesOnDeactivate = false
            window.setContentSize(NSSize(width: 510, height: 540))
            window.minSize = NSSize(width: 475, height: 500)
            // Keep the saved window position across the TouchTiles rename.
            window.setFrameAutosaveName("DriftTileSettings")
            if !window.setFrameUsingName("DriftTileSettings") { window.center() }
            window.isReleasedWhenClosed = false
            window.delegate = self
            settings = window
            state.onOpenSystemSettings = { [weak window] in window?.orderOut(nil) }
        }
        NSApp.activate(ignoringOtherApps: true)
        settings?.makeKeyAndOrderFront(nil)
    }

    func windowDidResignKey(_ notification: Notification) { state.stopRecording() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        state.shutdown()
        guard state.restorationPending else { return .terminateNow }
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
            guard self?.state.restorationPending != true else { return }
            timer.invalidate()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
enum TouchTilesApplication {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
