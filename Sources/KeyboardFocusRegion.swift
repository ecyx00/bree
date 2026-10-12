import Foundation

/// A top-level keyboard focus region of a main window. The cycle shortcut
/// (F6 / Shift+F6) walks `cycleOrder`, skipping regions that are not available.
enum KeyboardFocusRegion: Equatable, CaseIterable {
    case leftSidebar
    case terminal
    /// The workspace's bottom panel (Cmd-J); skipped while it is hidden.
    case bottomPanel
    case rightSidebar
    case quickView

    /// Cycle order: left sidebar, terminal / main content, bottom panel, right sidebar, Quick View.
    static let cycleOrder: [KeyboardFocusRegion] = [.leftSidebar, .terminal, .bottomPanel, .rightSidebar, .quickView]

    /// The next region after `current` in `order` for which `isAvailable` holds.
    /// Wraps around and falls back to `current` when nothing else is available.
    static func next(
        after current: KeyboardFocusRegion,
        forward: Bool,
        isAvailable: (KeyboardFocusRegion) -> Bool
    ) -> KeyboardFocusRegion {
        let order = forward ? cycleOrder : Array(cycleOrder.reversed())
        guard let start = order.firstIndex(of: current) else { return .terminal }
        for offset in 1...order.count {
            let candidate = order[(start + offset) % order.count]
            if candidate != current, isAvailable(candidate) { return candidate }
        }
        return current
    }
}
