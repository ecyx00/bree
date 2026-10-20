import Foundation

// The surface model: terminals, VNC displays and browsers are *resources*; panes are
// *projections* of them. A resource has exactly one identity and zero or more
// projections, on this Mac or on a remote machine. Every entrypoint — the right-sidebar
// tree, drag and drop, the socket, the CLI — reads and mutates the same catalog, so
// "is this terminal open somewhere?" has one answer and closing a pane never destroys a
// remote resource. Pure values here; the owner is `SurfaceCatalog`.

public enum SurfaceResourceKind: String, Codable, Sendable, CaseIterable {
    case terminal
    /// A VNC display on the machine ("display", never "screen": a bree-tui `screen` is a
    /// split tree inside a workspace, a different thing).
    case display
    case browser

    /// Wire-tolerant parse: pre-rename catalogs, persisted sessions, and older CLIs say
    /// `screen` for a VNC display. Emit `display`, accept both.
    public init?(wire: String) {
        if wire == "screen" {
            self = .display
            return
        }
        self.init(rawValue: wire)
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let kind = SurfaceResourceKind(wire: raw) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown surface resource kind '\(raw)'"
            ))
        }
        self = kind
    }
}

/// Stable identity of a resource. `key` is the provider's own id: a local panel UUID
/// string, a bree-tui `term_…`/`browser_…` id, `display:1` for a VNC display, or
/// `port:<n>` for a forwarded port's browser.
public struct SurfaceResourceID: Hashable, Codable, Sendable, CustomStringConvertible {
    public var machine: SurfaceMachineID
    public var kind: SurfaceResourceKind
    public var key: String

    public var description: String { "\(machine.rawValue)/\(kind.rawValue)/\(key)" }

    /// Wire form `<machine>/<kind>/<key>`; keys may contain `/` (URLs), so split only twice.
    public var rawValue: String { description }

    public init(machine: SurfaceMachineID, kind: SurfaceResourceKind, key: String) {
        self.machine = machine
        self.kind = kind
        self.key = key
    }

    public init?(rawValue: String) {
        let parts = rawValue.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let kind = SurfaceResourceKind(wire: String(parts[1])), !parts[2].isEmpty else { return nil }
        self.init(machine: SurfaceMachineID(rawValue: String(parts[0])), kind: kind, key: String(parts[2]))
    }
}

public enum SurfaceLifecycle: String, Codable, Sendable {
    case launching
    case running
    case exited
    /// The machine is asleep or its link is down; the resource is known but not reachable now.
    case unavailable
}

public struct SurfaceAgentBadge: Hashable, Codable, Sendable {
    public var state: String
    public var source: String?
    /// The adapter identity, separate from report provenance (`hook`, `socket`, or `plugin`).
    public var agent: String? = nil

    public init(state: String, source: String? = nil, agent: String? = nil) {
        self.state = state
        self.source = source
        self.agent = agent
    }
}

/// The bree-tui workspace a remote resource belongs to (nil for local resources).
/// Device workspaces (another Mac's sidebar) additionally carry the cwd, unread
/// count, and pin state the Mac sidebar shows; remote workspaces leave them nil.
public struct SurfaceRemoteWorkspace: Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var index: Int
    public var focused: Bool
    /// The workspace's presented working directory, when the provider reports one.
    public var detail: String? = nil
    /// The remote sidebar's unread badge count, when the provider reports one.
    public var unreadCount: Int? = nil
    /// Whether the workspace is pinned on its machine, when the provider reports it.
    public var isPinned: Bool? = nil

    public init(
        id: String,
        name: String,
        index: Int,
        focused: Bool,
        detail: String? = nil,
        unreadCount: Int? = nil,
        isPinned: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.index = index
        self.focused = focused
        self.detail = detail
        self.unreadCount = unreadCount
        self.isPinned = isPinned
    }
}

/// One view of a remote resource: a tab in one of the daemon's workspaces. A resource
/// has zero or more views; closing a view never kills the resource.
public struct SurfaceRemoteView: Hashable, Codable, Sendable {
    public var tabID: String
    public var workspace: SurfaceRemoteWorkspace
    /// Exact graph coordinates. They make a local pane's rename target stable even
    /// when the same terminal is present in several workspaces.
    public var screenID: String? = nil
    public var paneID: String? = nil
    public var name: String? = nil
    public var index: Int? = nil
    /// True when this tab is the one its pane shows; the daemon flags exactly one
    /// tab per pane. The pane's other tabs sit behind it in its tab bar.
    public var focused: Bool? = nil
    /// Where the tab's pane sits in the workspace's layout: the screen's index and
    /// the pane's depth-first position in that screen's split tree. nil when the
    /// snapshot carried no layout document (older daemons, focused snapshots).
    public var screenIndex: Int? = nil
    public var paneIndex: Int? = nil

    public init(
        tabID: String,
        workspace: SurfaceRemoteWorkspace,
        screenID: String? = nil,
        paneID: String? = nil,
        name: String? = nil,
        index: Int? = nil,
        focused: Bool? = nil,
        screenIndex: Int? = nil,
        paneIndex: Int? = nil
    ) {
        self.tabID = tabID
        self.workspace = workspace
        self.screenID = screenID
        self.paneID = paneID
        self.name = name
        self.index = index
        self.focused = focused
        self.screenIndex = screenIndex
        self.paneIndex = paneIndex
    }
}

public struct SurfaceResource: Identifiable, Hashable, Codable, Sendable {
    public var id: SurfaceResourceID
    public var title: String
    /// cwd for terminals, URL for browsers, display name for screens.
    public var detail: String?
    public var lifecycle: SurfaceLifecycle
    public var agent: SurfaceAgentBadge?
    /// The workspace of the resource's first view (compat: pre-multi-view callers read
    /// one workspace). nil when the resource has zero views, or is local.
    public var remoteWorkspace: SurfaceRemoteWorkspace?
    /// Every view of a remote resource, in the daemon's canonical tab order. nil when the
    /// provider does not model views (local resources, displays, port browsers); an empty
    /// array is a live resource with zero views (it belongs in the machine's pool).
    public var remoteViews: [SurfaceRemoteView]? = nil
    /// For screens and port browsers: the port on the machine.
    public var port: Int?
    /// For browsers and screens: the private URL the projection loads after the
    /// browser Network Extension is ready.
    public var url: String?

    public var machine: SurfaceMachineID { id.machine }
    public var kind: SurfaceResourceKind { id.kind }

    /// How many remote views (daemon tabs) show this resource; 0 when views are not modeled.
    public var remoteViewCount: Int { remoteViews?.count ?? 0 }

    /// A live remote terminal no daemon tab shows: it keeps running on the machine
    /// and is out of every workspace's layout, so it lists only in the machine's
    /// Terminals group, greyed as "detached"; a click re-attaches it in a pane and
    /// only its kill verb ends it. Exited and unavailable records are never marked
    /// detached, even when stale tab ids leave an empty resolved-view list.
    public var isDetachedTerminal: Bool {
        guard kind == .terminal, remoteViews?.isEmpty == true else { return false }
        switch lifecycle {
        case .launching, .running:
            return true
        case .exited, .unavailable:
            return false
        }
    }

    /// The daemon workspaces holding at least one view, first-view order, deduped.
    /// Falls back to `remoteWorkspace` for providers that report a single workspace.
    public var remoteWorkspaces: [SurfaceRemoteWorkspace] {
        guard let remoteViews else { return remoteWorkspace.map { [$0] } ?? [] }
        var seen = Set<String>()
        var result: [SurfaceRemoteWorkspace] = []
        for view in remoteViews where seen.insert(view.workspace.id).inserted {
            result.append(view.workspace)
        }
        return result
    }

    public init(
        id: SurfaceResourceID,
        title: String,
        detail: String? = nil,
        lifecycle: SurfaceLifecycle,
        agent: SurfaceAgentBadge? = nil,
        remoteWorkspace: SurfaceRemoteWorkspace? = nil,
        remoteViews: [SurfaceRemoteView]? = nil,
        port: Int? = nil,
        url: String? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.lifecycle = lifecycle
        self.agent = agent
        self.remoteWorkspace = remoteWorkspace
        self.remoteViews = remoteViews
        self.port = port
        self.url = url
    }
}

/// One pane showing one resource.
public struct SurfaceProjection: Hashable, Codable, Sendable {
    public var resource: SurfaceResourceID
    public var workspaceID: UUID
    public var panelID: UUID
    /// The remote placement represented by this local pane, if it came from a
    /// Remote graph. A terminal id alone is not enough because tab names are
    /// placement-local.
    public var remoteWorkspaceID: String? = nil
    public var remoteTabID: String? = nil

    public init(
        resource: SurfaceResourceID,
        workspaceID: UUID,
        panelID: UUID,
        remoteWorkspaceID: String? = nil,
        remoteTabID: String? = nil
    ) {
        self.resource = resource
        self.workspaceID = workspaceID
        self.panelID = panelID
        self.remoteWorkspaceID = remoteWorkspaceID
        self.remoteTabID = remoteTabID
    }
}

public enum SurfaceSplitDirection: String, Codable, Sendable {
    case left, right, up, down
}

/// Where to project. Mirrors the socket params `workspace_id` / `pane_id` / `direction` /
/// `tab_index`; `.workspace` splits that workspace's focused pane to the right (or tabs
/// when `placement` is `.tab`).
public enum SurfaceDestination: Hashable, Sendable {
    case workspace(id: UUID, placement: SurfacePlacement)
    case split(workspaceID: UUID, paneID: String, direction: SurfaceSplitDirection)
    case tab(workspaceID: UUID, paneID: String, index: Int?)

    public var workspaceID: UUID {
        switch self {
        case .workspace(let id, _): return id
        case .split(let id, _, _): return id
        case .tab(let id, _, _): return id
        }
    }
}

public enum SurfacePlacement: String, Codable, Sendable {
    case split
    case tab
}

public enum SurfaceLinkState: String, Codable, Sendable {
    case connected
    case connecting
    case asleep
    case unavailable
    case error
    /// Another Mac that the presence service reports offline (app quit, asleep, or
    /// unreachable); its last known tree stays listed until it comes back.
    case offline
    /// The local Mac needs no link.
    case notApplicable = "n/a"
}

/// One atomic export for agent and socket readers. The sidebar consumes only
/// `catalog`; the complete daemon graphs stay out of its high-frequency value.
/// Both halves are captured in the same main-actor turn, so their cursors and
/// derived resource rows always describe one accepted state.
public struct SurfaceCatalogExport: Sendable {
    public var catalog: SurfaceCatalogSnapshot
    /// Existing stable local owner IDs, captured beside this read's runtime projections.
    /// Missing owners remain unknown; these values never become resource or mutation IDs.
    public var projectionIdentities: [SurfaceProjection: SurfaceProjectionIdentity] = [:]

    public init(
        catalog: SurfaceCatalogSnapshot,
        projectionIdentities: [SurfaceProjection: SurfaceProjectionIdentity] = [:]
    ) {
        self.catalog = catalog
        self.projectionIdentities = projectionIdentities
    }
}

/// Persisted with the session: which resource each pane projected, so a restored pane
/// re-projects a remote resource instead of becoming an anonymous shell.
public struct SurfaceProjectionRecord: Hashable, Codable, Sendable {
    public var panelID: UUID
    public var resource: SurfaceResourceID
    public var remoteWorkspaceID: String? = nil
    public var remoteTabID: String? = nil

    public init(
        panelID: UUID,
        resource: SurfaceResourceID,
        remoteWorkspaceID: String? = nil,
        remoteTabID: String? = nil
    ) {
        self.panelID = panelID
        self.resource = resource
        self.remoteWorkspaceID = remoteWorkspaceID
        self.remoteTabID = remoteTabID
    }
}

public enum SurfaceCatalogError: Error, LocalizedError, Equatable {
    case unknownResource(SurfaceResourceID)
    case noProvider(SurfaceMachineID)
    case unavailable(SurfaceResourceID, reason: String)
    case ambiguousRemotePlacement(SurfaceResourceID, workspaceID: String)
    case destinationNotFound(String)
    case unsupported(String)
    /// The target exists but holds nothing to open (an empty remote workspace).
    case nothingToOpen(String)
    /// A multi-step remote operation stopped after at least one committed step.
    /// The caller must not hide this behind a generic transport error: the
    /// remote graph may now contain a deliberate partial result.
    case partialOperation(SurfaceResourceID, reason: String)

    public var errorDescription: String? {
        switch self {
        case .unknownResource(let id):
            return String(format: String(localized: "surfaceCatalog.error.unknownResource", defaultValue: "Unknown surface %@."), id.rawValue)
        case .noProvider(let machine):
            return String(format: String(localized: "surfaceCatalog.error.noProvider", defaultValue: "This machine is not connected: %@."), machine.rawValue)
        case .unavailable(let id, let reason):
            return String(format: String(localized: "surfaceCatalog.error.unavailable", defaultValue: "%1$@ is unavailable: %2$@"), id.rawValue, reason)
        case .ambiguousRemotePlacement:
            // Resource and workspace identifiers are internal routing data. Do
            // not expose them in a user-facing error; callers can choose the
            // exact placement with `remote_tab_id`.
            return String(
                localized: "surfaceCatalog.error.ambiguousRemotePlacement",
                defaultValue: "This terminal has more than one remote placement. Specify the remote tab."
            )
        case .destinationNotFound(let what):
            return String(format: String(localized: "surfaceCatalog.error.destinationNotFound", defaultValue: "Destination not found: %@."), what)
        case .unsupported(let what):
            return String(format: String(localized: "surfaceCatalog.error.unsupported", defaultValue: "Unsupported: %@."), what)
        case .nothingToOpen(let what):
            return String(format: String(localized: "surfaceCatalog.error.nothingToOpen", defaultValue: "Nothing to open: %@."), what)
        case .partialOperation(_, let reason): return reason
        }
    }
}
