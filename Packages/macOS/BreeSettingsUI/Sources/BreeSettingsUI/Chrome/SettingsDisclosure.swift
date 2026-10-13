import SwiftUI

/// Collapsed-by-default group for rarely changed settings. Rows inside stay
/// searchable but are only scrollable once the group is open.
@MainActor
struct SettingsDisclosure<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 14) {
                content()
            }
            .padding(.top, 8)
        } label: {
            Text(title)
                .breeFont(.title)
        }
    }
}
