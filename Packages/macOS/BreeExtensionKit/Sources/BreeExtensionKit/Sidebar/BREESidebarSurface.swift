import Foundation

/// The user-visible kind of a bree sidebar surface.
public enum BreeSidebarSurfaceKind: String, Codable, CaseIterable, Equatable, Sendable {
    /// A terminal surface backed by the embedded terminal emulator.
    case terminal
    /// A browser surface.
    case browser
    /// A markdown preview surface.
    case markdown
    /// A file preview surface.
    case filePreview
    /// A right-sidebar tool surface.
    case rightSidebarTool
    /// A project/file explorer surface.
    case project
    /// A surface kind that is not known by this SDK version.
    case unknown

    /// Creates a surface kind, preserving forward compatibility for unknown raw values.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = BreeSidebarSurfaceKind(rawValue: rawValue) ?? .unknown
    }
}

/// A sidebar surface exposed to bree extensions.
public struct BreeSidebarSurface: Codable, Equatable, Identifiable, Sendable {
    /// The stable surface identifier.
    public var id: UUID
    /// The current surface title.
    public var title: String
    /// The kind of surface.
    public var kind: BreeSidebarSurfaceKind
    /// Whether the surface is currently focused.
    public var isFocused: Bool
    /// Whether the surface is pinned.
    public var isPinned: Bool
    /// The unread item count shown for the surface.
    public var unreadCount: Int
    /// The surface working directory when the extension has permission to see workspace paths.
    public var workingDirectory: String?

    /// Creates a sidebar surface value.
    public init(
        id: UUID,
        title: String,
        kind: BreeSidebarSurfaceKind = .unknown,
        isFocused: Bool = false,
        isPinned: Bool = false,
        unreadCount: Int = 0,
        workingDirectory: String? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.isFocused = isFocused
        self.isPinned = isPinned
        self.unreadCount = unreadCount
        self.workingDirectory = workingDirectory
    }

    @_spi(BreeHostTransport)
    /// Returns a copy filtered to the data scopes granted to an extension.
    public func filtered(for scopes: some Sequence<BreeExtensionScope>) -> BreeSidebarSurface {
        let scopeSet = Set(scopes)
        return BreeSidebarSurface(
            id: id,
            title: title,
            kind: kind,
            isFocused: isFocused,
            isPinned: isPinned,
            unreadCount: unreadCount,
            workingDirectory: scopeSet.contains(.workspacePaths) ? workingDirectory : nil
        )
    }
}
