import Foundation

/// Settings under the dotted-id prefix `sidebar.*` — workspace-row
/// metadata visibility and layout.
public struct SidebarCatalogSection: SettingCatalogSection {
    /// Valid notification-preview line limits for settings UI and configuration parsing.
    public static let notificationMessageLineLimitRange = 1...50

    /// Resolves the shipped legacy layout contract together with the newer
    /// branch/directory placement preference.
    public static func stacksBranchAndDirectory(
        vertical: Bool,
        explicit: Bool
    ) -> Bool {
        vertical || explicit
    }

    public let hideAllDetails = DefaultsKey<Bool>(
        id: "sidebar.hideAllDetails",
        defaultValue: false,
        userDefaultsKey: "sidebarHideAllDetails"
    )

    public let wrapWorkspaceTitles = DefaultsKey<Bool>(
        id: "sidebar.wrapWorkspaceTitles",
        defaultValue: false,
        userDefaultsKey: "sidebarWrapWorkspaceTitles"
    )

    public let showWorkspaceDescription = DefaultsKey<Bool>(
        id: "sidebar.showWorkspaceDescription",
        defaultValue: true,
        userDefaultsKey: "sidebarShowWorkspaceDescription"
    )

    public let workspaceDescriptionColorHex = DefaultsKey<String>(
        id: "sidebar.workspaceDescriptionColor",
        defaultValue: "",
        userDefaultsKey: "sidebarWorkspaceDescriptionColorHex"
    )

    /// Bool-backed to match the legacy in-app store. The on-disk key
    /// `sidebarBranchVerticalLayout` is written as a Bool by every
    /// shipped bree build; using an enum here would silently revert
    /// every user with a saved preference. `true` preserves the legacy
    /// vertical presentation: each panel's branch/directory record gets its
    /// own row, with branch and directory on separate subrows. When this is
    /// `false`, `stackBranchDirectory` can still opt the compact branch layout
    /// into separate branch and directory subrows.
    public let branchVerticalLayout = DefaultsKey<Bool>(
        id: "sidebar.branchVerticalLayout",
        defaultValue: true,
        userDefaultsKey: "sidebarBranchVerticalLayout"
    )

    public let stackBranchDirectory = DefaultsKey<Bool>(
        id: "sidebar.stackBranchDirectory",
        defaultValue: false,
        userDefaultsKey: "sidebarBranchDirectoryStacked"
    )

    public let pathLastSegmentOnly = DefaultsKey<Bool>(
        id: "sidebar.pathLastSegmentOnly",
        defaultValue: false,
        userDefaultsKey: "sidebarPathLastSegmentOnly"
    )

    public let showNotificationMessage = DefaultsKey<Bool>(
        id: "sidebar.showNotificationMessage",
        defaultValue: true,
        userDefaultsKey: "sidebarShowNotificationMessage"
    )

    /// Maximum notification-preview lines shown per workspace, defaulting to 3.
    public let notificationMessageLineLimit = DefaultsKey<Int>(
        id: "sidebar.notificationMessageLineLimit",
        defaultValue: 3,
        userDefaultsKey: "sidebarNotificationMessageLineLimit"
    )

    public let showBranchDirectory = DefaultsKey<Bool>(
        id: "sidebar.showBranchDirectory",
        defaultValue: true,
        userDefaultsKey: "sidebarShowBranchDirectory"
    )

    public let watchGitStatus = DefaultsKey<Bool>(
        id: "sidebar.watchGitStatus",
        defaultValue: true,
        userDefaultsKey: "sidebarWatchGitStatus"
    )

    public let openPortLinksInBreeBrowser = DefaultsKey<Bool>(
        id: "sidebar.openPortLinksInBreeBrowser",
        defaultValue: true,
        userDefaultsKey: "browserOpenSidebarPortLinksInBreeBrowser"
    )

    public let showSSH = DefaultsKey<Bool>(
        id: "sidebar.showSSH",
        defaultValue: true,
        userDefaultsKey: "sidebarShowSSH"
    )

    public let showPorts = DefaultsKey<Bool>(
        id: "sidebar.showPorts",
        defaultValue: true,
        userDefaultsKey: "sidebarShowPorts"
    )

    public let showLog = DefaultsKey<Bool>(
        id: "sidebar.showLog",
        defaultValue: true,
        userDefaultsKey: "sidebarShowLog"
    )

    public let showProgress = DefaultsKey<Bool>(
        id: "sidebar.showProgress",
        defaultValue: true,
        userDefaultsKey: "sidebarShowProgress"
    )

    /// Whether sidebar workspace rows append coding-agent usage (model,
    /// context-window percentage, estimated API cost) to the agent status
    /// entry (`sidebar.showAgentUsage`). Defaults to off: sampling reads the
    /// agent transcript off the main actor after hook events.
    public let showAgentUsage = DefaultsKey<Bool>(
        id: "sidebar.showAgentUsage",
        defaultValue: false,
        userDefaultsKey: "sidebarShowAgentUsage"
    )

    /// Whether coding-agent status entries reported by agent hooks (for
    /// example Claude Code's "Running") render as a tinted glyph on the
    /// workspace title line instead of their own metadata row
    /// (`sidebar.compactAgentStatus`). Defaults to on; other status entries
    /// keep their rows either way.
    public let compactAgentStatus = DefaultsKey<Bool>(
        id: "sidebar.compactAgentStatus",
        defaultValue: true,
        userDefaultsKey: "sidebarCompactAgentStatus"
    )

    /// `sidebar.compactAgentStatus` glyph overrides: SF Symbol names keyed by
    /// state (`needsInput`, `terminal`, ...).
    public let compactStatusIcons = DefaultsKey<[String: String]>(
        id: "sidebar.compactStatusIcons",
        defaultValue: [:],
        userDefaultsKey: "sidebarCompactStatusIcons"
    )

    public let showCustomMetadata = DefaultsKey<Bool>(
        id: "sidebar.showCustomMetadata",
        defaultValue: true,
        userDefaultsKey: "sidebarShowStatusPills"
    )

    public let rightMaxWidth = DefaultsKey<Double>(
        id: "sidebar.rightMaxWidth",
        defaultValue: RightSidebarWidthSettings.noOverrideValue,
        userDefaultsKey: RightSidebarWidthSettings.maxWidthKey
    )

    public let rememberedRightMaxWidth = DefaultsKey<Double>(
        id: "sidebar.rightMaxWidth.remembered",
        defaultValue: RightSidebarWidthSettings.defaultConfiguredMaximumWidth,
        userDefaultsKey: RightSidebarWidthSettings.rememberedMaxWidthKey
    )

    public let activeTabIndicatorStyle = DefaultsKey<String>(
        id: "sidebar.activeTabIndicatorStyle",
        defaultValue: "leftRail",
        userDefaultsKey: "sidebarActiveTabIndicatorStyle"
    )

    public let selectionColorHex = DefaultsKey<String>(
        id: "sidebar.selectionColor",
        defaultValue: "",
        userDefaultsKey: "sidebarSelectionColorHex"
    )

    public let notificationBadgeColorHex = DefaultsKey<String>(
        id: "sidebar.notificationBadgeColor",
        defaultValue: "",
        userDefaultsKey: "sidebarNotificationBadgeColorHex"
    )

    public init() {}
}
