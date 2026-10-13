import AppKit
import BreeSettings
import SwiftUI

/// Read-only, searchable list of every bound shortcut, grouped like the
/// Settings list and showing the effective (user-overridden) chords.
@MainActor
final class KeyboardShortcutsCheatSheetController: NSObject, NSWindowDelegate {
    static let shared = KeyboardShortcutsCheatSheetController()
    private var window: NSWindow?

    func toggle() {
        if let window, window.isVisible, window.isKeyWindow {
            window.close()
        } else {
            show()
        }
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = String(localized: "settings.section.keyboardShortcuts", defaultValue: "Keyboard Shortcuts")
        window.contentView = NSHostingView(rootView: KeyboardShortcutsCheatSheetView(onCustomize: {
            AppDelegate.shared?.openPreferencesWindow(
                debugSource: "keyboardShortcuts.cheatSheet",
                navigationTarget: .keyboardShortcuts
            )
        }))
        window.delegate = self
        window.setFrameAutosaveName("KeyboardShortcutsCheatSheet")
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        window = nil
    }
}

/// One cheat-sheet row. Pure data so tests can assert grouping without UI.
struct KeyboardShortcutsCheatSheetRow: Identifiable, Equatable {
    let action: KeyboardShortcutSettings.Action
    let label: String
    let chord: String
    var id: String { action.rawValue }
}

struct KeyboardShortcutsCheatSheetSection: Identifiable, Equatable {
    let group: ShortcutAction.Group
    let rows: [KeyboardShortcutsCheatSheetRow]
    var id: String { group.rawValue }

    var title: String {
        switch group {
        case .app: return String(localized: "shortcutDiscovery.section.app", defaultValue: "App")
        case .workspace: return String(localized: "shortcutDiscovery.section.workspace", defaultValue: "Workspace")
        case .navigation: return String(localized: "shortcutDiscovery.section.navigation", defaultValue: "Navigation")
        case .panes: return String(localized: "shortcutDiscovery.section.panes", defaultValue: "Panes")
        case .browser: return String(localized: "shortcutDiscovery.section.browser", defaultValue: "Browser & Find")
        }
    }

    /// Bound actions only, in Settings order, grouped by the Settings group model.
    /// `query` filters on the label or the chord text, case-insensitively.
    static func build(query: String = "") -> [KeyboardShortcutsCheatSheetSection] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var byGroup: [ShortcutAction.Group: [KeyboardShortcutsCheatSheetRow]] = [:]
        for action in KeyboardShortcutSettings.settingsVisibleActions {
            let shortcut = KeyboardShortcutSettings.shortcut(for: action)
            guard !shortcut.isUnbound,
                  let group = ShortcutAction(rawValue: action.rawValue)?.group else { continue }
            let row = KeyboardShortcutsCheatSheetRow(action: action, label: action.label, chord: shortcut.displayString)
            if !trimmed.isEmpty,
               !row.label.localizedCaseInsensitiveContains(trimmed),
               !row.chord.localizedCaseInsensitiveContains(trimmed) {
                continue
            }
            byGroup[group, default: []].append(row)
        }
        return ShortcutAction.Group.allCases.compactMap { group in
            byGroup[group].map { KeyboardShortcutsCheatSheetSection(group: group, rows: $0) }
        }
    }
}

struct KeyboardShortcutsCheatSheetView: View {
    let onCustomize: () -> Void
    @State private var query = ""
    @State private var revision = 0

    var body: some View {
        let _ = revision  // re-render when shortcut settings change
        let sections = KeyboardShortcutsCheatSheetSection.build(query: query)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField(
                    String(localized: "shortcutsCheatSheet.search", defaultValue: "Search shortcuts"),
                    text: $query
                )
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(String(localized: "shortcutsCheatSheet.search", defaultValue: "Search shortcuts"))
                Button(String(localized: "shortcutsCheatSheet.customize", defaultValue: "Customize…"), action: onCustomize)
            }
            .padding(12)
            Divider()
            if sections.isEmpty {
                Text(String(localized: "shortcutsCheatSheet.empty", defaultValue: "No matching shortcuts"))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(sections) { section in
                        Section(section.title) {
                            ForEach(section.rows) { row in
                                HStack {
                                    Text(row.label)
                                    Spacer()
                                    Text(row.chord)
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel("\(row.label), \(row.chord)")
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 360)
        .onReceive(NotificationCenter.default.publisher(for: KeyboardShortcutSettings.didChangeNotification)) { _ in
            revision += 1
        }
    }
}
