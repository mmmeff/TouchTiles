import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

enum GestureModifier: String, CaseIterable, Identifiable {
    case command = "Command"
    case option = "Option"
    case controlOption = "Control + Option"

    var id: Self { self }
    var flags: CGEventFlags {
        switch self {
        case .command: return .maskCommand
        case .option: return .maskAlternate
        case .controlOption: return [.maskControl, .maskAlternate]
        }
    }
}

final class AppState: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var access = AXIsProcessTrusted()
    @Published private(set) var login = SMAppService.mainApp.status
    @Published private(set) var bindings: [WindowAction: KeyBinding] = [:]
    @Published private(set) var conflicts: [WindowAction: String] = [:]
    @Published private(set) var modifier: GestureModifier
    @Published private(set) var tileLimits: TileLimits
    @Published private(set) var gestureIssue: String?
    @Published private(set) var floatingPreviews: Bool
    @Published private(set) var screenCaptureAllowed = false
    @Published private(set) var floatingPreviewIssue: String?
    @Published var message: String?
    @Published var recording: WindowAction?
    var onAppearanceChange: (() -> Void)?
    var onOpenSystemSettings: (() -> Void)?
    private let desktop = WindowManager()
    private let shortcuts = Shortcuts()
    private let gestures = GestureInput()
    private let prefs = UserDefaults.standard
    private var lifecycleTimer: Timer?
    private var recorder: Any?
    private var resumeWhenTrusted = false
    private var restoreWhenTrusted = false

    init() {
        modifier = GestureModifier(rawValue: UserDefaults.standard.string(forKey: "gestureModifier") ?? "") ?? .command
        let defaults = UserDefaults.standard
        floatingPreviews = defaults.bool(forKey: "floatingPreviews")
        let initial = TileLimits()
        tileLimits = TileLimits(rows: defaults.object(forKey: "maximumRows") as? Int ?? initial.rows,
                                columns: defaults.object(forKey: "maximumColumns") as? Int ?? initial.columns)
        desktop.setLimits(tileLimits)
        for action in WindowAction.allCases {
            let data = prefs.data(forKey: Self.key(action))
            bindings[action] = data.flatMap { try? JSONDecoder().decode(KeyBinding.self, from: $0) } ?? action.defaultBinding
        }
        gestures.onGesture = { [weak self] event in
            guard let self, self.enabled else { return }
            self.desktop.handle(event)
        }
        gestures.onStatus = { [weak self] issue in
            self?.gestureIssue = issue
            self?.onAppearanceChange?()
        }
        shortcuts.onPress = { [weak self] action in self?.perform(action) }
        desktop.isRecordingShortcut = { [weak self] in self?.recording != nil }
        desktop.onError = { [weak self] issue in self?.message = issue; self?.onAppearanceChange?() }
        desktop.onFloatingPreviewIssue = { [weak self] issue in
            self?.floatingPreviewIssue = issue
            self?.onAppearanceChange?()
        }
        updatePreviewAccess()
    }

    private static func key(_ action: WindowAction) -> String { "shortcut.\(action.rawValue)" }
    var restorationPending: Bool { desktop.restorationPending }
    var needsPreviewAccess: Bool { floatingPreviews && !screenCaptureAllowed }

    func launch() {
        if prefs.bool(forKey: "tilingEnabled") {
            if access { setEnabled(true) }
            else {
                resumeWhenTrusted = true
                message = "Restore Accessibility access to resume your saved tiling mode."
            }
        }
        lifecycleTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let trusted = AXIsProcessTrusted()
            if trusted != self.access {
                self.access = trusted
                if !trusted && self.enabled {
                    self.enabled = false
                    self.stopRecording(resume: false)
                    self.shortcuts.stop()
                    self.gestures.stop()
                    self.conflicts.removeAll()
                    self.desktop.suspend()
                    self.restoreWhenTrusted = true
                    self.prefs.set(false, forKey: "tilingEnabled")
                    self.message = "Accessibility access was removed. Grant it again to restore your previous window positions."
                } else if trusted {
                    if self.restoreWhenTrusted {
                        self.restoreWhenTrusted = false
                        self.desktop.stop()
                        self.message = nil
                    }
                    if self.resumeWhenTrusted {
                        self.resumeWhenTrusted = false
                        self.setEnabled(true)
                    }
                }
                self.onAppearanceChange?()
            }
            let login = SMAppService.mainApp.status
            if self.login != login { self.login = login }
            self.updatePreviewAccess()
        }
    }

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        stopRecording(resume: false)
        message = nil
        if value {
            guard !desktop.restorationPending else {
                message = "Wait for your previous window positions to return, then turn on tiling."
                return
            }
            access = AXIsProcessTrusted()
            guard access else {
                requestAccess()
                message = "Grant Accessibility access, then turn on tiling."
                return
            }
            if restoreWhenTrusted {
                restoreWhenTrusted = false
                desktop.stop()
                if desktop.restorationPending {
                    message = "Wait for your previous window positions to return, then turn on tiling."
                    return
                }
            }
            guard desktop.supportsWindowIdentity else {
                message = "This version of macOS does not expose the window IDs TouchTiles needs."
                return
            }
            resumeShortcuts()
            enabled = true
            desktop.start()
            gestures.start(modifiers: modifier.flags)
        } else {
            enabled = false
            shortcuts.stop()
            conflicts.removeAll()
            gestures.stop()
            gestureIssue = nil
            desktop.stop()
        }
        prefs.set(value, forKey: "tilingEnabled")
        onAppearanceChange?()
    }

    private func resumeShortcuts() {
        conflicts.removeAll()
        for action in WindowAction.allCases {
            do {
                try shortcuts.register(bindings[action] ?? action.defaultBinding, for: action)
            } catch {
                conflicts[action] = error.localizedDescription
            }
        }
        onAppearanceChange?()
    }

    func setModifier(_ choice: GestureModifier) {
        guard choice != modifier else { return }
        if enabled { gestures.stop(); desktop.handle(.cancelled) }
        modifier = choice
        prefs.set(choice.rawValue, forKey: "gestureModifier")
        if enabled { gestures.start(modifiers: choice.flags) }
    }

    func setFloatingPreviews(_ value: Bool) {
        guard floatingPreviews != value else { return }
        floatingPreviews = value
        prefs.set(value, forKey: "floatingPreviews")
        updatePreviewAccess()
    }

    private func updatePreviewAccess() {
        let allowed = floatingPreviews && CGPreflightScreenCaptureAccess()
        guard allowed != screenCaptureAllowed else { return }
        screenCaptureAllowed = allowed
        desktop.setFloatingPreviewsEnabled(allowed)
        onAppearanceChange?()
    }

    func requestPreviewAccess() {
        guard floatingPreviews else { return }
        if !CGRequestScreenCaptureAccess() { openSettings("com.apple.preference.security?Privacy_ScreenCapture") }
        updatePreviewAccess()
    }

    func setTileLimits(_ limits: TileLimits) {
        guard limits != tileLimits else { return }
        prefs.set(limits.rows, forKey: "maximumRows")
        prefs.set(limits.columns, forKey: "maximumColumns")
        tileLimits = limits
        desktop.setLimits(limits)
    }

    func record(_ action: WindowAction) {
        stopRecording(resume: false)
        shortcuts.stop()
        message = nil
        recording = action
        recorder = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { self.stopRecording(); return nil }
            do {
                let binding = try KeyBinding(recording: event)
                try self.save(binding, for: action)
                self.stopRecording()
            } catch { self.message = error.localizedDescription }
            return nil
        }
    }

    private func save(_ binding: KeyBinding, for action: WindowAction) throws {
        guard !bindings.contains(where: { $0.key != action && $0.value.matches(binding) }) else {
            throw ShortcutError.message("That combination is already assigned to the other window action.")
        }
        try binding.checkSystemShortcut()
        // Test third-party registrations too. Release the probe before committing.
        let probe = Shortcuts()
        defer { probe.stop() }
        try probe.register(binding, for: action)
        let data = try JSONEncoder().encode(binding)
        prefs.set(data, forKey: Self.key(action))
        bindings[action] = binding
        message = nil
    }

    func stopRecording(resume: Bool = true) {
        guard recording != nil else { return }
        if let recorder { NSEvent.removeMonitor(recorder) }
        recorder = nil
        recording = nil
        if resume && enabled { resumeShortcuts() }
    }

    func perform(_ action: WindowAction) { if enabled { desktop.perform(action) } }
    func spaceChanged() { if enabled { desktop.spaceChanged() } }

    func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        access = AXIsProcessTrustedWithOptions(options)
        if !access { openSettings("com.apple.preference.security?Privacy_Accessibility") }
    }

    func openSettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:" + pane), NSWorkspace.shared.open(url) else { return }
        onOpenSystemSettings?()
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
        onOpenSystemSettings?()
    }

    func setLogin(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            message = nil
        } catch {
            message = "Login item: \(error.localizedDescription) Move TouchTiles to Applications and try again."
        }
        login = SMAppService.mainApp.status
    }

    func shutdown() {
        lifecycleTimer?.invalidate()
        stopRecording(resume: false)
        shortcuts.stop()
        gestures.stop()
        if enabled {
            enabled = false
            desktop.stop()
        }
    }
}
