import Foundation

/// Which Dock backing store a `DockSplitStore` uses.
///
/// - ``workspace``: the per-workspace Dock that powers the bottom panel,
///   seeded from the project `.cmux/dock.json` resolved upward from that
///   workspace's directory. Its live panels belong to the workspace and are
///   torn down when the workspace closes.
enum DockScope: String, Codable, Sendable {
    case workspace
}
