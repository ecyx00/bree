public import AppKit
public import BreeTerminalCore
public import GhosttyKit

/// The inner terminal NSView a ``TerminalSurface`` renders into.
///
/// The concrete view (`GhosttyNSView`) lives above this package in the view
/// layer; the surface model drives it exclusively through this seam plus the
/// `NSView` superclass surface (bounds, window, layer, backing conversions).
/// The protocol also refines `TerminalSurfaceHosting` because the ghostty
/// callback context identifies its host view through that core seam.
@MainActor
public protocol TerminalSurfaceNativeViewing: NSView, TerminalSurfaceHosting {
    /// The owning workspace id mirrored onto the view for focus routing.
    var tabId: UUID? { get set }

    /// The key-state indicator text currently shown for this view
    /// (copy-mode/key-table), or nil when no indicator applies.
    var currentKeyStateIndicatorText: String? { get }

    /// Whether keyboard copy mode is active on this view.
    var isKeyboardCopyModeActive: Bool { get }

    /// Toggles keyboard copy mode.
    ///
    /// - Returns: Whether the view handled the toggle.
    @discardableResult
    func toggleKeyboardCopyMode() -> Bool

    /// Ends keyboard copy mode and clears its selection when focus leaves the view.
    func cancelKeyboardCopyMode()

    /// Re-applies the window background for the active surface.
    func applyWindowBackgroundIfActive()

    /// Forces a synchronous surface size/draw refresh.
    ///
    /// - Returns: Whether a refresh was performed.
    @discardableResult
    func forceRefreshSurface() -> Bool

    /// Whether a window portal positions this view and therefore owns the
    /// pane geometry it may publish. A portal-owned view never derives a
    /// terminal size from its own bounds; it waits for the portal's commit.
    var paneGeometryIsPortalOwned: Bool { get }

    /// Monotonic count of drawables vended by the native renderer.
    ///
    /// Hosts that do not expose a Metal layer use the default zero value; the
    /// macOS Ghostty host supplies its atomic drawable sequence.
    var renderedFrameSequence: UInt64 { get }

    /// Reconciles view-owned state after a new native Ghostty surface lifetime
    /// is installed.
    func runtimeSurfaceDidBecomeReady()

    /// Defers programmatic runtime input behind an active clipboard read.
    ///
    /// - Parameters:
    ///   - estimatedBytes: Approximate retained payload size for queue bounds.
    ///   - replay: The input mutation to retry after the clipboard read ends.
    /// - Returns: Whether the input was accepted for deferred replay.
    @discardableResult
    func deferRuntimeInputDuringClipboardRead(
        estimatedBytes: Int,
        replay: @escaping () -> Void
    ) -> Bool

}

public extension TerminalSurfaceNativeViewing {
    var renderedFrameSequence: UInt64 { 0 }

    /// Views outside a portal size themselves from their own bounds.
    var paneGeometryIsPortalOwned: Bool { false }

    /// Leaves input synchronous for hosts without clipboard sequencing.
    ///
    /// - Parameters:
    ///   - estimatedBytes: Approximate retained payload size; unused by the
    ///     synchronous default.
    ///   - replay: The input mutation; unused because the caller continues
    ///     synchronously when this method returns `false`.
    /// - Returns: Always `false`.
    @discardableResult
    func deferRuntimeInputDuringClipboardRead(
        estimatedBytes _: Int,
        replay _: @escaping () -> Void
    ) -> Bool {
        false
    }
}
