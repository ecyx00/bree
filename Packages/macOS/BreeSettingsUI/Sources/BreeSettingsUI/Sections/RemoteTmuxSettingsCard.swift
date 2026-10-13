import BreeFoundation
import BreeSettings
import SwiftUI

/// Remote tmux opt-in, shown in the Advanced pane (formerly under Beta Features).
@MainActor
public struct RemoteTmuxSettingsCard: View {
    @State private var remoteTmux: DefaultsValueModel<Bool>

    public init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        _remoteTmux = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.betaFeatures.remoteTmux))
    }

    public var body: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .settingsOnly,
                searchAnchorID: "setting:advanced:remoteTmux",
                String(localized: "settings.betaFeatures.remoteTmux", defaultValue: "Remote tmux"),
                subtitle: String(localized: "settings.betaFeatures.remoteTmux.subtitle", defaultValue: "Shows tmux sessions on remote hosts as workspaces in the sidebar. The sessions keep running after Bree quits.")
            ) {
                Toggle("", isOn: Binding(get: { remoteTmux.current }, set: { remoteTmux.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsBetaRemoteTmuxToggle")
            }
        }
        .task { remoteTmux.startObserving() }
    }
}
