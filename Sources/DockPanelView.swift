import AppKit
import Bonsplit
import CmuxAppKitSupportUI
import CmuxFoundation
import CmuxNotifications
import CmuxTerminal
import SwiftUI

/// Bottom panel. Renders the workspace's Dock `BonsplitController` tree
/// (terminals + browsers) using the same split machinery as the main content
/// area, below the main split. Every workspace mounts its own store.
struct DockPanelView: View {
    let store: DockSplitStore
    /// True when the panel is open and its workspace is the visible one.
    let isPanelVisible: Bool
    let rootDirectory: String?
    let windowAppearance: WindowAppearanceSnapshot
    /// True when the panel owns keyboard focus (the name is historical). The
    /// panel dims its focus ring when false so panel and main-pane focus are
    /// mutually exclusive (the main pane dims its ring when this is true).
    var rightSidebarOwnsInputFocus: Bool = false

    @State private var appearanceConfig = WorkspaceContentView.resolveGhosttyAppearanceConfig(reason: "dock.initial")
    @State private var appearanceRevision: UInt = 0
    @State private var unreadProjection: DockUnreadPanelProjection
    @State private var visibilityHostId = UUID()

    @MainActor
    init(
        store: DockSplitStore,
        isPanelVisible: Bool,
        rootDirectory: String?,
        windowAppearance: WindowAppearanceSnapshot,
        rightSidebarOwnsInputFocus: Bool = false,
        unreadSource: SidebarUnreadModel
    ) {
        self.store = store
        self.isPanelVisible = isPanelVisible
        self.rootDirectory = rootDirectory
        self.windowAppearance = windowAppearance
        self.rightSidebarOwnsInputFocus = rightSidebarOwnsInputFocus
        _unreadProjection = State(initialValue: DockUnreadPanelProjection(
            source: unreadSource,
            workspaceID: store.workspaceId,
            panelIDs: Set(store.panels.keys),
            isActive: isPanelVisible,
            agentAttentionSource: store.agentNeedsInputAttention
        ))
    }

    private var appearance: PanelAppearance {
        PanelAppearance.fromConfig(appearanceConfig)
    }

    private var resolvedChromeBackgroundIdentity: String {
        windowAppearance.resolvedChromeBackgroundColor.hexString(includeAlpha: true)
    }

    var body: some View {
        content
        // Bonsplit and hosted panel subtrees may create their own AppKit
        // hosting boundary. Re-inject the snapshot authority at the Dock root
        // so none of that chrome falls back to macOS's ambient appearance.
        .environment(\.colorScheme, windowAppearance.resolvedColorScheme)
        // The window root (or the right-sidebar material) owns the backdrop.
        // Bonsplit terminal surfaces are intentionally clear, so a concrete
        // composited chrome color here would cut them off from that owner.
        .background(
            WindowBackdropLayer(role: .bonsplitChrome, snapshot: windowAppearance)
        )
        .background(
            DockKeyboardFocusBridge(store: store, registersHost: isPanelVisible)
                .frame(width: 1, height: 1)
        )
        .background(
            DockUnreadProjectionContextBridge(
                projection: unreadProjection,
                panelIDs: Set(store.panels.keys),
                isActive: isPanelVisible
            )
            .frame(width: 0, height: 0)
        )
        // Keep the container identifiable without replacing its hosted controls' identities.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("DockPanel")
        .onAppear {
            refreshAppearance(reason: "onAppear")
            store.setRootDirectory(rootDirectory)
            store.setActive(isVisible: isPanelVisible, visibilityHostId: visibilityHostId)
            focusIfRequested()
        }
        .onDisappear { store.setVisibleInUI(false, hostId: visibilityHostId) }
        .onChange(of: isPanelVisible) { _, visible in
            store.setActive(isVisible: visible, visibilityHostId: visibilityHostId)
            focusIfRequested()
        }
        .onChange(of: rootDirectory) { _, _ in
            store.setRootDirectory(rootDirectory)
            store.setActive(isVisible: isPanelVisible, visibilityHostId: visibilityHostId)
        }
        .onReceive(NotificationCenter.default.publisher(for: PaneChromeSettings.didChangeNotification)) { _ in
            refreshAppearance(reason: "paneChromeSettingsDidChange")
        }
        .onDisplayAccessibilityOptionsChange { _ in
            refreshAppearance(reason: "displayAccessibilityOptionsDidChange")
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyDefaultBackgroundDidChange)) { _ in
            refreshAppearance(reason: "ghosttyDefaultBackgroundDidChange")
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyChromeConfigurationDidChange)) { _ in
            refreshAppearance(reason: "ghosttyChromeConfigurationDidChange")
        }
        .onChange(of: windowAppearance.resolvedColorScheme) { _, _ in
            // The Dock's Bonsplit controller is an AppKit subtree and does not
            // inherit SwiftUI's environment automatically. Re-apply its
            // concrete chrome whenever the shared theme authority changes.
            refreshAppearance(reason: "resolvedColorSchemeChanged")
        }
        .onChange(of: resolvedChromeBackgroundIdentity) { _, _ in
            refreshAppearance(reason: "resolvedChromeBackgroundChanged")
        }
    }

    /// Moves focus into the panel once, after the host mounted and the panel is visible.
    private func focusIfRequested() {
        guard isPanelVisible, store.wantsBottomPanelFocusOnAppear else { return }
        store.wantsBottomPanelFocusOnAppear = false
        DispatchQueue.main.async { [weak store] in
            _ = store?.focusFirstControl()
        }
    }

    private func refreshAppearance(reason: String) {
        let next = WorkspaceContentView.resolveGhosttyAppearanceConfig(reason: "dock.\(reason)")
        appearanceConfig = next
        appearanceRevision &+= 1
        store.applyGhosttyChrome(from: next, windowAppearance: windowAppearance)
    }

    @ViewBuilder
    private var content: some View {
        if let trustRequest = store.trustRequest {
            DockTrustView(request: trustRequest) {
                store.trustAndReload()
            }
        } else if let error = store.errorMessage {
            DockErrorView(message: error)
        } else {
            DockSplitContentView(
                store: store,
                appearance: appearance,
                appearanceRevision: appearanceRevision,
                windowAppearance: windowAppearance,
                rightSidebarOwnsInputFocus: rightSidebarOwnsInputFocus,
                unreadPanelIDs: unreadProjection.unreadPanelIDs
            )
        }
    }
}

/// Shown in an empty Dock pane (initial empty Dock, or a freshly split pane).
/// Offers the same in-app create affordances as the tab-bar split buttons.
struct DockEmptyPaneView: View {
    let onNewTerminal: () -> Void
    let onNewBrowser: () -> Void
    @State private var browserAvailable = BrowserAvailabilitySettings.isEnabled()
    private var palette: BreeChromePalette { BreeChromePaletteStore.shared.palette }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "dock.rectangle")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(palette.glyphTertiary)
            Text(String(localized: "dock.emptyPane.title", defaultValue: "Empty Panel"))
                .breeFont(.title)
                .foregroundStyle(palette.textSecondary)
            HStack(spacing: 8) {
                Button(action: onNewTerminal) {
                    Label(
                        String(localized: "dock.action.newTerminal", defaultValue: "New Terminal"),
                        systemImage: "terminal.fill"
                    )
                }
                if BrowserAvailabilitySettings.offersBrowserAffordance(isEnabled: browserAvailable) {
                    Button(action: onNewBrowser) {
                        Label(
                            String(localized: "dock.action.newBrowser", defaultValue: "New Browser"),
                            systemImage: "globe"
                        )
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(BreeMetrics.spacing16)
        .background(palette.surfaceSunken)
        .trackingBrowserAffordanceAvailability($browserAvailable)
    }
}

private struct DockTrustView: View {
    let request: DockTrustRequest
    let onTrust: () -> Void
    private var palette: BreeChromePalette { BreeChromePaletteStore.shared.palette }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.shield")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(palette.signalAttention)
            Text(String(localized: "dock.trust.title", defaultValue: "Trust Project Dock?"))
                .breeFont(.title)
                .foregroundStyle(palette.textPrimary)
            Text(String(
                localized: "dock.trust.message",
                defaultValue: "This project wants to start commands from its Dock config."
            ))
            .breeFont(.secondary)
            .foregroundStyle(palette.textSecondary)
            .multilineTextAlignment(.center)
            Text(request.configPath)
                .breeFont(.mono)
                .foregroundStyle(palette.textSecondary)
                .lineLimit(2)
                .truncationMode(.middle)
            Button(String(localized: "dock.trust.action", defaultValue: "Trust and Start")) {
                onTrust()
            }
            .buttonStyle(.breeProminent)
            .tint(palette.accentFill)
            .foregroundStyle(palette.surfaceBase)
            .controlSize(.small)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.surfaceSunken)
    }
}

private struct DockErrorView: View {
    let message: String
    private var palette: BreeChromePalette { BreeChromePaletteStore.shared.palette }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(palette.signalError)
            Text(String(localized: "dock.error.title", defaultValue: "Dock Config Error"))
                .breeFont(.title)
                .foregroundStyle(palette.textPrimary)
            Text(message)
                .breeFont(.secondary)
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.surfaceSunken)
    }
}

private struct DockKeyboardFocusBridge: NSViewRepresentable {
    let store: DockSplitStore
    /// Only the visible workspace's panel may own the window's single dock host slot.
    let registersHost: Bool

    func makeNSView(context: Context) -> DockKeyboardFocusView {
        DockKeyboardFocusView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    func updateNSView(_ nsView: DockKeyboardFocusView, context: Context) {
        nsView.focusFirstControl = { [weak store] in
            store?.focusFirstControl() == true
        }
        nsView.ownsDockBrowserFocus = { [weak store] responder, window in
            store?.browserPanel(owning: responder, in: window) != nil
        }
        nsView.registersHost = registersHost
        nsView.registerWithKeyboardFocusCoordinatorIfNeeded()
    }
}

final class DockKeyboardFocusView: NSView {
    var focusFirstControl: (() -> Bool)?
    var ownsDockBrowserFocus: ((NSResponder, NSWindow) -> Bool)?
    var registersHost = true
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); registerWithKeyboardFocusCoordinatorIfNeeded() }

    func registerWithKeyboardFocusCoordinatorIfNeeded() { if registersHost, let window { AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.registerDockHost(self) } }

    func ownsKeyboardFocus(_ responder: NSResponder) -> Bool {
        if responder === self { return true }
        if let window, ownsDockBrowserFocus?(responder, window) == true { return true }
        guard let ghosttyView = responder.cmuxStrictOwningGhosttyView(),
              let surfaceId = ghosttyView.terminalSurface?.id else {
            return false
        }
        return GhosttyApp.terminalSurfaceRegistry.isRightSidebarDockSurface(id: surfaceId)
    }

    func focusFirstItemFromCoordinator() { _ = focusFirstControl?() }

    func focusHostFromCoordinator() -> Bool {
        focusFirstControl?() == true || window?.makeFirstResponder(self) == true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool { handleModeShortcut(event) || super.performKeyEquivalent(with: event) }

    override func keyDown(with event: NSEvent) { if !handleModeShortcut(event) { super.keyDown(with: event) } }

    private func handleModeShortcut(_ event: NSEvent) -> Bool {
        guard let mode = AppDelegate.shared?.rightSidebarModeShortcut(for: event) else { return false }
        _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(mode: mode, focusFirstItem: true, preferredWindow: window)
        return true
    }
}
