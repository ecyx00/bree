extension KeyboardShortcutSettings.Action {
    /// Whether this action is part of the public, user-configurable shortcut catalog.
    var isPublicShortcutAction: Bool {
        switch self {
        case .switchRightSidebarToFiles,
             .switchRightSidebarToSessions,
             .switchRightSidebarToActivity,
             .switchRightSidebarToArchitecture:
            return false
        default:
            return true
        }
    }
}
