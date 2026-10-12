public import Foundation

/// Resolved visibility of the auxiliary detail rows under a sidebar
/// workspace row (metadata pills, log line, progress, branch/directory,
/// ports, coding-agent usage).
///
/// The master "hide all details" switch wins over every individual toggle;
/// ``resolved(showMetadata:showLog:showProgress:showAgentUsage:showBranchDirectory:showPorts:hideAllDetails:)``
/// applies exactly that legacy precedence.
public struct SidebarWorkspaceAuxiliaryDetailVisibility: Equatable, Sendable {
    /// Whether custom metadata pills are shown.
    public let showsMetadata: Bool
    /// Whether the latest log line is shown.
    public let showsLog: Bool
    /// Whether agent progress is shown.
    public let showsProgress: Bool
    /// Whether coding-agent usage (model, context %, estimated cost) is
    /// appended to the agent status entry.
    public let showsAgentUsage: Bool
    /// Whether the branch/directory line is shown.
    public let showsBranchDirectory: Bool
    /// Whether forwarded-port rows are shown.
    public let showsPorts: Bool

    /// Local git metadata is needed only when at least one git-backed detail
    /// row is visible. Callers combine this with the user's master
    /// `watchGitStatus` preference.
    public var requiresGitMetadata: Bool {
        showsBranchDirectory
    }

    /// Creates a visibility value with each row's flag as given.
    ///
    /// `showsAgentUsage` defaults to `false` because agent usage is an
    /// opt-in detail (`sidebar.showAgentUsage`).
    public init(
        showsMetadata: Bool,
        showsLog: Bool,
        showsProgress: Bool,
        showsBranchDirectory: Bool,
        showsPorts: Bool,
        showsAgentUsage: Bool = false
    ) {
        self.showsMetadata = showsMetadata
        self.showsLog = showsLog
        self.showsProgress = showsProgress
        self.showsAgentUsage = showsAgentUsage
        self.showsBranchDirectory = showsBranchDirectory
        self.showsPorts = showsPorts
    }

    /// Every row hidden.
    public static let hidden = Self(
        showsMetadata: false,
        showsLog: false,
        showsProgress: false,
        showsBranchDirectory: false,
        showsPorts: false
    )

    /// Combines the individual row toggles with the master "hide all
    /// details" switch: when `hideAllDetails` is set every row is hidden
    /// regardless of its own toggle.
    public static func resolved(
        showMetadata: Bool,
        showLog: Bool,
        showProgress: Bool,
        showAgentUsage: Bool = false,
        showBranchDirectory: Bool,
        showPorts: Bool,
        hideAllDetails: Bool
    ) -> Self {
        guard !hideAllDetails else { return .hidden }
        return Self(
            showsMetadata: showMetadata,
            showsLog: showLog,
            showsProgress: showProgress,
            showsBranchDirectory: showBranchDirectory,
            showsPorts: showPorts,
            showsAgentUsage: showAgentUsage
        )
    }
}
