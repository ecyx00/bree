import SwiftUI
import BreeAppKitSupportUI

/// A Bonsplit terminal tab whose panel registry entry is stale must remain
/// explainable instead of falling through to an empty view.
struct TerminalPanelUnavailableView: View {
    let appearance: PanelAppearance

    var body: some View {
        VStack(spacing: 10) {
            BreeSystemSymbolImage(
                magnified: "exclamationmark.triangle",
                pointSize: 28,
                tint: Color(nsColor: .secondaryLabelColor)
            )
            Text(String(localized: "Remote.overlay.manual.unavailable.title", defaultValue: "Remote terminal unavailable"))
                .scaledFont(size: 14, weight: .semibold)
                .foregroundStyle(.primary)
            Text(String(localized: "Remote.overlay.manual.reopen.detail", defaultValue: "Close this tab and reopen the terminal from the remote sidebar."))
                .scaledFont(size: 12)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: appearance.contentBackgroundColor))
        .ghosttyDialogTheme()
    }
}
