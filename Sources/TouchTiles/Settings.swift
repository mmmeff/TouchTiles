import ServiceManagement
import SwiftUI

private enum SettingsPage: String, CaseIterable {
    case desktop = "Desktop"
    case controls = "Controls"
}

struct SettingsView: View {
    @ObservedObject var state: AppState
    @State private var page = SettingsPage.desktop

    var body: some View {
        VStack(spacing: 0) {
            Picker("Settings", selection: $page) {
                ForEach(SettingsPage.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 244).padding(.vertical, 15)
            Divider()
            Form {
                switch page {
                case .desktop: desktop
                case .controls: controls
                }
                if let message = state.message {
                    Section {
                        Label(message, systemImage: "exclamationmark.circle")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 475, idealWidth: 510, minHeight: 490, idealHeight: 540)
        .onChange(of: page) { _ in state.stopRecording() }
        .onDisappear { state.stopRecording() }
    }

    @ViewBuilder private var desktop: some View {
        Section {
            Toggle(isOn: Binding(get: { state.enabled }, set: { state.setEnabled($0) })) {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Automatic tiling").font(.headline)
                        Text("Arrange windows on each display.").font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "rectangle.split.2x1").font(.title2).foregroundStyle(Color.accentColor)
                }
            }.toggleStyle(.switch).accessibilityLabel("Automatic tiling").padding(.vertical, 4)
        } footer: {
            Text("Turning tiling off restores your windows and releases the shortcuts and trackpad gestures.")
        }
        Section {
            limitRow("Maximum rows", value: state.tileLimits.rows) { rows in
                state.setTileLimits(TileLimits(rows: rows, columns: state.tileLimits.columns))
            }
            limitRow("Maximum columns", value: state.tileLimits.columns) { columns in
                state.setTileLimits(TileLimits(rows: state.tileLimits.rows, columns: columns))
            }
        } header: { Text("Layout per display") } footer: {
            Text("A window floats until there’s a tile that can fit its minimum size within these limits.")
        }
        Section {
            Toggle("Show covered floating windows", isOn: Binding(
                get: { state.floatingPreviews }, set: { state.setFloatingPreviews($0) }
            )).toggleStyle(.switch)
            if state.floatingPreviews {
                LabeledContent("Screen Recording") {
                    if state.screenCaptureAllowed {
                        Label("Allowed", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    } else {
                        Button("Grant screen access…") { state.requestPreviewAccess() }
                    }
                }
                if let issue = state.floatingPreviewIssue {
                    Text(issue).font(.callout).foregroundStyle(.secondary)
                }
            }
        } header: { Text("Floating windows") } footer: {
            Text("Show a local live preview when a tile covers a floating window. Hover over the preview to use the original window.")
        }
        Section("Startup") {
            Toggle("Open at login", isOn: Binding(
                get: { state.login == .enabled || state.login == .requiresApproval },
                set: { state.setLogin($0) }
            )).toggleStyle(.switch)
            if state.login == .requiresApproval {
                Button("Approve TouchTiles in Login Items…") { state.openLoginItems() }
            }
        }
        Section {
            LabeledContent("Accessibility") {
                if state.access {
                    Label("Allowed", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                } else {
                    Button("Grant access…") { state.requestAccess() }
                }
            }
        } header: { Text("Permissions") } footer: {
            Text("TouchTiles uses Accessibility to move, resize, and focus other apps’ windows.")
        }
        if let issue = state.gestureIssue { gestureAccess(issue) }
    }

    @ViewBuilder private var controls: some View {
        Section {
            ForEach(WindowAction.allCases) { action in
                LabeledContent(action.title) {
                    Button {
                        if state.recording == action { state.stopRecording() } else { state.record(action) }
                    } label: {
                        Text(state.recording == action ? "Press shortcut…" : (state.bindings[action] ?? action.defaultBinding).display)
                            .font(.system(.body, design: .monospaced)).frame(minWidth: 78)
                    }
                    .help(state.recording == action ? "Press Escape to cancel" : "Record a new shortcut")
                    .accessibilityLabel("Record shortcut for " + action.title)
                }
                if let conflict = state.conflicts[action] {
                    Text(conflict).font(.callout).foregroundStyle(.secondary)
                }
            }
        } header: { Text("Window shortcuts") } footer: {
            Text(state.recording == nil ? "Shortcuts work while tiling is on." : "Hold Option, or two or more modifiers, and press a key. Escape cancels.")
        }
        Section {
            Picker("Hold while gesturing", selection: Binding(get: { state.modifier }, set: { state.setModifier($0) })) {
                ForEach(GestureModifier.allCases) { Text($0.rawValue).tag($0) }
            }
            LabeledContent("Resize window", value: "Two-finger scroll")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Resize window").accessibilityValue("Two-finger scroll")
            LabeledContent("Move window", value: "Three-finger swipe")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Move window").accessibilityValue("Three-finger swipe")
        } header: { Text("Trackpad") } footer: {
            Text("Place the pointer in the corner you want to resize, then scroll with both fingers together. To move a window, swipe with three fingers. Neighboring tiles make room as you move.")
        }
        Section {
            Button("Trackpad settings…") { state.openSettings("com.apple.Trackpad-Settings.extension") }
        } footer: {
            Text("If a three-finger swipe also switches Spaces or opens Mission Control, assign that macOS gesture to four fingers in More Gestures.")
        }
        if let issue = state.gestureIssue { gestureAccess(issue) }
    }

    private func limitRow(_ title: String, value: Int, set: @escaping (Int) -> Void) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text(value, format: .number).monospacedDigit()
                Stepper(title, value: Binding(get: { value }, set: set), in: 1...Int.max)
                    .labelsHidden().accessibilityValue(String(value))
            }
        }
    }

    private func gestureAccess(_ issue: String) -> some View {
        Section("Trackpad input") {
            Text(issue).fixedSize(horizontal: false, vertical: true)
            Button("Input Monitoring settings…") { state.openSettings("com.apple.preference.security?Privacy_ListenEvent") }
        }
    }
}
