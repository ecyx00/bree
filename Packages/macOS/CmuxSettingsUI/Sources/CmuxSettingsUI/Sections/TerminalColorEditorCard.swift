import CmuxFoundation
import SwiftUI

/// Terminal color editor for the Themes section: background, foreground,
/// cursor, selection, and the 16 ANSI colors.
///
/// Each picker starts at the color in effect for the current theme. A change is
/// written, after a short pause, as an override in cmux's Ghostty config (the
/// same file the Terminal option rows edit) and applied by a config reload.
/// "Reset to Theme" removes only those overrides.
@MainActor
struct TerminalColorEditorCard: View {
    let hostActions: SettingsHostActions

    @State private var effective = GhosttyTerminalColors()
    @State private var overrides = GhosttyTerminalColors()
    @State private var hasLoaded = false
    @State private var saveFailed = false
    /// Bumped on every edit and reload so each picker reconciles to `effective`.
    @State private var revision = 0
    @State private var tasks = MainActorTaskStore<String>()

    private static let writeDelay: Duration = .milliseconds(250)
    private static let writeTaskKey = "colors"
    private static let fallbackHex = "#808080"

    var body: some View {
        SettingsCard {
            SettingsCardNote(String(
                localized: "settings.terminal.colors.note",
                defaultValue: "Starts from the colors of your current theme. Changes are saved as overrides in Bree's Ghostty config and apply right away."
            ))
            if saveFailed {
                Text(String(
                    localized: "settings.terminal.colors.saveFailed",
                    defaultValue: "Couldn't save the colors. Please try again."
                ))
                .breeFont(.secondary)
                .foregroundStyle(.settingsError)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            SettingsCardDivider()
            colorRow(.background, "background", String(localized: "settings.terminal.colors.background", defaultValue: "Background"))
            SettingsCardDivider()
            colorRow(.foreground, "foreground", String(localized: "settings.terminal.colors.foreground", defaultValue: "Foreground"))
            SettingsCardDivider()
            colorRow(.cursor, "cursor-color", String(localized: "settings.terminal.colors.cursor", defaultValue: "Cursor"))
            SettingsCardDivider()
            colorRow(.selectionBackground, "selection-background", String(localized: "settings.terminal.colors.selectionBackground", defaultValue: "Selection Background"))
            SettingsCardDivider()
            colorRow(.selectionForeground, "selection-foreground", String(localized: "settings.terminal.colors.selectionForeground", defaultValue: "Selection Foreground"))
            SettingsCardDivider()
            paletteRow(
                String(localized: "settings.terminal.colors.palette.normal", defaultValue: "ANSI Colors 0-7"),
                indexes: 0...7
            )
            SettingsCardDivider()
            paletteRow(
                String(localized: "settings.terminal.colors.palette.bright", defaultValue: "ANSI Colors 8-15"),
                indexes: 8...15
            )
            SettingsCardDivider()
            previewRow
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .settingsOnly,
                searchAnchorID: "setting:themes:terminal-colors",
                String(localized: "settings.terminal.colors.reset", defaultValue: "Reset to Theme"),
                subtitle: String(
                    localized: "settings.terminal.colors.reset.subtitle",
                    defaultValue: "Removes only these color overrides. Your theme and other settings stay as they are."
                )
            ) {
                Button(String(localized: "settings.terminal.colors.reset", defaultValue: "Reset to Theme")) {
                    resetToTheme()
                }
                .disabled(overrides.isEmpty)
                .accessibilityIdentifier("SettingsTerminalColorsResetButton")
            }
        }
        .disabled(!hasLoaded)
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .settingsTerminalThemeDidChange)) { _ in
            // The host reloads terminals asynchronously; read the effective colors after it settled.
            tasks.replaceOnMainActor("themeReload") {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                await load()
            }
        }
    }

    // MARK: Rows

    private func colorRow(_ slot: GhosttyTerminalColorSlot, _ key: String, _ title: String) -> some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:themes:terminal-color-\(key)",
            title,
            subtitle: key
        ) {
            HStack(spacing: 8) {
                Text(verbatim: hex(for: slot))
                    .breeFont(.mono)
                    .foregroundStyle(.settingsSecondaryText)
                picker(for: slot, label: title)
            }
        }
    }

    private func paletteRow(_ title: String, indexes: ClosedRange<Int>) -> some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:themes:terminal-palette-\(indexes.lowerBound)",
            title,
            subtitle: "palette"
        ) {
            HStack(spacing: 2) {
                ForEach(Array(indexes), id: \.self) { index in
                    picker(
                        for: .palette(index),
                        label: String.localizedStringWithFormat(
                            String(localized: "settings.terminal.colors.paletteEntry", defaultValue: "ANSI color %lld"),
                            Int64(index)
                        )
                    )
                }
            }
        }
    }

    private func picker(for slot: GhosttyTerminalColorSlot, label: String) -> some View {
        HexColorPicker(
            storedHex: hex(for: slot),
            fallback: Color(cmuxHex: Self.fallbackHex) ?? .gray,
            reconcileRevision: revision
        ) { newHex in
            set(slot, to: newHex)
        }
        .help(label)
        .accessibilityLabel(label)
    }

    /// A few lines of sample terminal output drawn with the colors being edited.
    private var previewRow: some View {
        let background = color(.background)
        let foreground = color(.foreground)
        return VStack(alignment: .leading, spacing: 2) {
            previewLine([("user@bree", 2), ("  ~/code ", 4), ("$ ", -1), ("git status", -1)], foreground)
            previewLine([("On branch ", -1), ("main", 6)], foreground)
            previewLine([("  modified:   ", 1), ("README.md", 3)], foreground)
            previewLine([("  new file:   ", 2), ("notes.txt", 5)], foreground)
            previewLine([("error: ", 9), ("warning: ", 11), ("ok ", 10), ("info", 12), (" debug", 13), (" trace", 14)], foreground)
            HStack(spacing: 0) {
                ForEach(GhosttyTerminalColorSlot.paletteRange, id: \.self) { index in
                    Rectangle().fill(color(.palette(index))).frame(width: 16, height: 10)
                }
            }
            .padding(.top, 4)
            HStack(spacing: 0) {
                Text(verbatim: "selected text")
                    .foregroundStyle(color(.selectionForeground))
                    .background(color(.selectionBackground))
                Text(verbatim: " ").foregroundStyle(background).background(color(.cursor))
            }
            .breeFont(.mono)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: BreeMetrics.radiusCard, style: .continuous).fill(background))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "settings.terminal.colors.preview", defaultValue: "Terminal color preview"))
    }

    /// One preview line; `ansi` index -1 uses the foreground color.
    private func previewLine(_ parts: [(String, Int)], _ foreground: Color) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                Text(verbatim: part.0).foregroundStyle(part.1 < 0 ? foreground : color(.palette(part.1)))
            }
        }
        .breeFont(.mono)
    }

    // MARK: Values

    private func hex(for slot: GhosttyTerminalColorSlot) -> String {
        effective.hexBySlot[slot] ?? Self.fallbackHex
    }

    private func color(_ slot: GhosttyTerminalColorSlot) -> Color {
        Color(cmuxHex: hex(for: slot)) ?? .gray
    }

    // MARK: Loading and saving

    private func load() async {
        let snapshot = await hostActions.terminalColorSnapshot()
        effective = snapshot.effective
        overrides = snapshot.overrides
        revision &+= 1
        hasLoaded = true
    }

    /// Shows the new color at once, then writes every override after a short
    /// pause (a newer edit replaces this task, so a color-panel drag writes once).
    private func set(_ slot: GhosttyTerminalColorSlot, to newHex: String) {
        guard let normalized = GhosttyTerminalColors.normalizedHex(newHex),
              effective.hexBySlot[slot] != normalized else { return }
        effective.hexBySlot[slot] = normalized
        overrides.hexBySlot[slot] = normalized
        revision &+= 1
        let pending = overrides
        tasks.replaceOnMainActor(Self.writeTaskKey) {
            try? await Task.sleep(for: Self.writeDelay)
            guard !Task.isCancelled else { return }
            saveFailed = !(await hostActions.setTerminalColorOverrides(pending))
        }
    }

    private func resetToTheme() {
        overrides = GhosttyTerminalColors()
        tasks.replaceOnMainActor(Self.writeTaskKey) {
            let saved = await hostActions.setTerminalColorOverrides(GhosttyTerminalColors())
            saveFailed = !saved
            guard !Task.isCancelled else { return }
            let snapshot = await hostActions.terminalColorSnapshot()
            effective = snapshot.effective
            overrides = snapshot.overrides
            revision &+= 1
        }
    }
}

extension Notification.Name {
    /// Posted after the theme gallery changed or reverted the theme, so the color editor
    /// reloads its effective colors.
    static let settingsTerminalThemeDidChange = Notification.Name("CmuxSettingsUI.terminalThemeDidChange")
}
