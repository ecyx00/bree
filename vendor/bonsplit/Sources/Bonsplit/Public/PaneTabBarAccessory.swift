import SwiftUI

/// Host-supplied views shown in the trailing area of one pane tab bar.
public struct PaneTabBarAccessory {
    public var leading: AnyView?
    public var trailing: AnyView?

    public init(leading: AnyView? = nil, trailing: AnyView? = nil) {
        self.leading = leading
        self.trailing = trailing
    }
}
