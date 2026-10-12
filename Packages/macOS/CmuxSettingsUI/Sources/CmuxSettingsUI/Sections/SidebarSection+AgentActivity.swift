import CmuxSettings
import SwiftUI

extension SidebarSection {
    @ViewBuilder
    var agentActivityRows: some View {
        agentUsageRow
        SettingsCardDivider()
    }
}
