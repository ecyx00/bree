import CmuxFoundation
import CmuxSettings
import SwiftUI

/// **Themes** section: every color and appearance setting in one place.
/// App icon, the browser page theme, the adaptive
/// default theme toggle, and the terminal theme gallery with every theme
/// Ghostty ships.
@MainActor
public struct ThemesSection: View {
    private let hostActions: SettingsHostActions

    @State private var appIcon: DefaultsValueModel<AppIconMode>
    @State private var adaptiveDefaultTheme: DefaultsValueModel<Bool>
    @State private var browserTheme: DefaultsValueModel<BrowserThemeMode>

    private static let columnWidth: CGFloat = 196

    /// Creates the Themes settings section.
    ///
    /// - Parameters:
    ///   - defaultsStore: The store used to read and write theme settings.
    ///   - jsonStore: cmux.json, where the accent color choice is written.
    ///   - catalog: The catalog that provides the theme-related setting keys.
    ///   - errorLog: Records a failed accent color write.
    ///   - hostActions: Host callbacks for the terminal theme gallery and reloads.
    public init(
        defaultsStore: UserDefaultsSettingsStore,
        jsonStore: JSONConfigStore,
        catalog: SettingCatalog,
        errorLog: SettingsErrorLog,
        hostActions: SettingsHostActions
    ) {
        self.hostActions = hostActions
        _appIcon = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.appIcon))
        _adaptiveDefaultTheme = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.adaptiveDefaultTheme))
        _browserTheme = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.browser.theme))
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.themes", defaultValue: "Themes"), section: .themes)
            appCard
            SettingsCard {
                browserThemeRow
            }
            // Last: the gallery lists every theme and runs long.
            SettingsCard {
                adaptiveDefaultThemeRow
                SettingsCardDivider()
                TerminalThemeSettingsRows(hostActions: hostActions)
            }
            TerminalColorEditorCard(hostActions: hostActions)
        }
        .task { startSettingsObservation([appIcon, adaptiveDefaultTheme, browserTheme]) }
    }

    @ViewBuilder
    private var appCard: some View {
        SettingsCard {
            // Also under App. Both rows bind the same key and update each
            // other; search lands on the App row, so this one has no anchor.
            AppIconPickerRow(
                selectedMode: appIcon.current,
                onSelect: { appIcon.set($0) }
            )
        }
    }

    private var adaptiveDefaultThemeRow: some View {
        SettingsCardRow(
            configurationReview: .json("terminal.adaptiveDefaultTheme"),
            String(
                localized: "settings.terminal.adaptiveDefaultTheme",
                defaultValue: "Adapt Default Theme to Appearance"
            ),
            subtitle: String(localized: "settings.terminal.adaptiveDefaultTheme.subtitle", defaultValue: "Matches terminal colors to the light or dark appearance when no Ghostty theme or colors are set.")
        ) {
            Toggle(
                "",
                isOn: Binding(
                    get: { adaptiveDefaultTheme.current },
                    set: { enabled in
                        adaptiveDefaultTheme.set(enabled) {
                            @MainActor [hostActions] in
                            hostActions.terminalAdaptiveDefaultThemeDidChange()
                        }
                    }
                )
            )
            .labelsHidden()
            .controlSize(.small)
            .accessibilityIdentifier("SettingsTerminalAdaptiveDefaultThemeToggle")
        }
    }

    private var browserThemeRow: some View {
        SettingsCardRow(
            configurationReview: .json("browser.theme"),
            String(localized: "settings.browser.theme", defaultValue: "Browser Theme"),
            subtitle: String(localized: "settings.browser.theme.subtitle", defaultValue: "Choose light or dark pages for sites that support both. System matches the app appearance."),
            controlWidth: Self.columnWidth
        ) {
            Picker("", selection: Binding(get: { browserTheme.current }, set: { browserTheme.set($0) })) {
                ForEach(BrowserThemeMode.allCases, id: \.self) { mode in
                    Text(Self.browserThemeDisplayName(mode)).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private static func browserThemeDisplayName(_ mode: BrowserThemeMode) -> String {
        switch mode {
        case .system:
            return String(localized: "theme.system", defaultValue: "System")
        case .light:
            return String(localized: "theme.light", defaultValue: "Light")
        case .dark:
            return String(localized: "theme.dark", defaultValue: "Dark")
        }
    }
}
