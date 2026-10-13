import BreeSettings
import SwiftUI

extension SidebarSection {
    @ViewBuilder
    var agentActivityRows: some View {
        agentUsageRow
        SettingsCardDivider()
    }
}
