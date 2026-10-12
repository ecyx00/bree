import SwiftUI
import AppKit

struct SidebarWorkspaceLeadingStatusSlot: View {
    let showsBadge: Bool
    let unreadCount: Int
    let side: CGFloat
    let badgeFont: Font
    let badgeFillColor: Color
    let badgeTextColor: Color

    var body: some View {
        ZStack {
            if showsBadge {
                SidebarWorkspaceUnreadBadge(
                    unreadCount: unreadCount,
                    side: side,
                    font: badgeFont,
                    fillColor: badgeFillColor,
                    textColor: badgeTextColor
                )
            }
        }
        .frame(width: side, height: side)
        .clipped()
    }
}
