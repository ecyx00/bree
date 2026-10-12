import AppKit
import SwiftUI

// MARK: - State (visibility toggle)

final class FileExplorerState: ObservableObject {
    private static let modeKey = "rightSidebar.mode"
    private static let customSidebarNameKey = "rightSidebar.customSidebarName"
    private let defaults: UserDefaults

    @Published var isVisible: Bool {
        didSet {
            persistVisibility()
            NotificationCenter.default.post(name: .surfaceTabBarDynamicStateDidChange, object: nil)
        }
    }
    /// Hidden because the window was too narrow (SidePanelWidthFit), not by the
    /// person. Persisted as visible, so a narrow window neither changes the
    /// default for new windows nor the next launch. Set it before `isVisible`.
    var isAutoCollapsed = false {
        didSet { persistVisibility() }
    }

    /// The person showed the sidebar in a window narrower than
    /// `SidePanelWidthFit.rightSidebarMinimumWindowWidth`; the width rule
    /// leaves it alone until the window widens. Not persisted.
    var isNarrowPinned = false

    private func persistVisibility() {
        defaults.set(isVisible || isAutoCollapsed, forKey: "fileExplorer.isVisible")
    }
    /// Width of the active mode. Architecture remembers its own width; every
    /// other mode shares `fileExplorer.width`. `setMode` swaps the value, so
    /// views keep reading and writing this one property.
    @Published var width: CGFloat {
        didSet { defaults.set(Double(width), forKey: Self.widthKey(for: storedMode)) }
    }

    static let sharedDefaultWidth: CGFloat = 220
    static let architectureDefaultWidth: CGFloat = 520

    static func widthKey(for mode: RightSidebarMode) -> String {
        mode == .architecture ? "fileExplorer.width.architecture" : "fileExplorer.width"
    }

    /// The remembered width for `mode`, or its default when nothing is stored.
    static func persistedWidth(for mode: RightSidebarMode, defaults: UserDefaults = .standard) -> CGFloat {
        let stored = defaults.double(forKey: widthKey(for: mode))
        if stored > 0 { return CGFloat(stored) }
        return mode == .architecture ? architectureDefaultWidth : sharedDefaultWidth
    }

    /// Proportion of sidebar height allocated to the tab list (0.0-1.0).
    /// The file explorer gets the remaining space below.
    @Published var dividerPosition: CGFloat {
        didSet { defaults.set(Double(dividerPosition), forKey: "fileExplorer.dividerPosition") }
    }

    @Published private var storedMode: RightSidebarMode
    @Published private var storedCustomSidebarName: String?

    /// Whether the right sidebar (Files / Find / Dock / …) currently owns
    /// keyboard/input focus in this window. Driven by `MainWindowFocusController`
    /// from its exclusive focus `intent`. Used to make main-pane focus and
    /// right-sidebar (Dock) focus mutually exclusive — the main pane dims its
    /// focus ring when the sidebar owns focus, and vice versa. Runtime-only (not
    /// persisted).
    @Published var rightSidebarOwnsInputFocus: Bool = false

    /// Active mode for the right sidebar (file tree, search, sessions, or enabled beta modes).
    var mode: RightSidebarMode {
        get { storedMode }
        set { setMode(newValue) }
    }

    var customSidebarName: String? {
        storedCustomSidebarName
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isVisible = defaults.bool(forKey: "fileExplorer.isVisible")
        // A persisted "architecture" (older builds) falls back to Files.
        var storedMode = RightSidebarMode.from(cliArgument: defaults.string(forKey: Self.modeKey) ?? "") ?? .files
        if storedMode == .architecture { storedMode = .files }
        let initialMode = Self.visibleMode(storedMode, defaults: defaults)
        self.width = Self.persistedWidth(for: initialMode, defaults: defaults)
        let storedPosition = defaults.double(forKey: "fileExplorer.dividerPosition")
        self.dividerPosition = storedPosition > 0 ? CGFloat(storedPosition) : 0.6
        let customSidebarName = defaults.string(forKey: Self.customSidebarNameKey)?.nilIfEmpty
        self.storedCustomSidebarName = customSidebarName
        self.storedMode = initialMode
        defaults.set(self.storedMode.rawValue, forKey: Self.modeKey)
    }

    /// Re-lands the sidebar on a tab the mode bar shows. Unlike an explicit
    /// `mode` set (which may reveal a user-hidden tab: CLI, palette,
    /// notification routing), restore and preference changes never resurrect a
    /// hidden tab.
    func refreshModeAvailability(defaults: UserDefaults? = nil) {
        let defaults = defaults ?? self.defaults
        setMode(Self.visibleMode(storedMode, defaults: defaults), defaults: defaults)
    }

    func selectCustomSidebar(name rawName: String, defaults: UserDefaults? = nil) {
        let defaults = defaults ?? self.defaults
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        storedCustomSidebarName = name
        defaults.set(name, forKey: Self.customSidebarNameKey)
    }

    /// The persisted right-sidebar custom-sidebar name, readable without an
    /// instance (mode availability checks run from static contexts).
    static func persistedCustomSidebarName(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: customSidebarNameKey)?.nilIfEmpty
    }

    func toggle() {
        setVisible(!isVisible)
    }

    func setVisible(_ nextValue: Bool) {
        guard isVisible != nextValue else { return }

        // Suppress both SwiftUI transactions and AppKit/Core Animation implicit layout changes.
        NSAnimationContext.beginGrouping()
        CATransaction.begin()
        defer {
            CATransaction.commit()
            NSAnimationContext.endGrouping()
        }

        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        CATransaction.setDisableActions(true)

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isVisible = nextValue
        }
    }

    private func setMode(_ mode: RightSidebarMode, defaults: UserDefaults? = nil) {
        // Architecture is a popup, not a sidebar mode: never stored.
        guard mode != .architecture else { return }
        let defaults = defaults ?? self.defaults
        let nextMode = Self.availableMode(mode, defaults: defaults)
        guard storedMode != nextMode else {
            if defaults.string(forKey: Self.modeKey) != nextMode.rawValue {
                defaults.set(nextMode.rawValue, forKey: Self.modeKey)
            }
            return
        }
        storedMode = nextMode
        defaults.set(nextMode.rawValue, forKey: Self.modeKey)
        let nextWidth = Self.persistedWidth(for: nextMode, defaults: defaults)
        if abs(width - nextWidth) > 0.5 { width = nextWidth }
    }

    private static func availableMode(
        _ mode: RightSidebarMode,
        defaults: UserDefaults
    ) -> RightSidebarMode {
        mode.isAvailable(defaults: defaults) ? mode : .files
    }

    private static func visibleMode(
        _ mode: RightSidebarMode,
        defaults: UserDefaults
    ) -> RightSidebarMode {
        let candidate = availableMode(mode, defaults: defaults)
        // Custom sidebars are selectable content, not customizable mode-bar tabs.
        if candidate == .customSidebar { return candidate }
        let visible = RightSidebarMode.visibleModes(defaults: defaults)
        if visible.contains(candidate) { return candidate }
        return visible.first ?? candidate
    }
}
