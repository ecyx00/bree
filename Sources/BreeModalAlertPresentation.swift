import AppKit

/// How ``NSAlert/runBreeModal(presentingWindow:content:willPresent:)`` ended up
/// presenting an alert.
///
/// Reported to the `willPresent` hook from inside the presenter so callers
/// observe the *actual* path taken rather than re-deriving it (which can
/// drift from the presenter's own decision).
enum BreeModalAlertPresentation {
    /// Presented as a sheet attached to the associated host window.
    case sheet(NSWindow)
    /// Presented application-modal because no eligible host window was found.
    ///
    /// - Parameter hostWindowHadAttachedSheet: `true` when a candidate host
    ///   window existed but was rejected because it already had a sheet
    ///   attached; `false` when no candidate window was found at all.
    case appModal(hostWindowHadAttachedSheet: Bool)
}

private extension NSWindow {
    /// Whether this window is one of bree's main windows.
    var isBreeMainWindow: Bool {
        guard let raw = identifier?.rawValue else { return false }
        return raw == "bree.main" || raw.hasPrefix("bree.main.")
    }
}

extension NSApplication {
    /// Returns the visible main bree window best suited to host a modal sheet.
    ///
    /// Prefers `preferredWindow` when supplied and eligible, then the key
    /// window, then the main window, then any visible main window. Returns `nil`
    /// when no main bree window is currently on screen, in which case callers
    /// should fall back to an app-modal presentation.
    ///
    /// - Parameter preferredWindow: A window to consider ahead of the
    ///   key/main/any search, used when it is visible and a bree main window
    ///   (e.g. a `TabManager`'s own owning window).
    @MainActor
    func breeMainWindowForModalPresentation(preferring preferredWindow: NSWindow? = nil) -> NSWindow? {
        if let preferredWindow, preferredWindow.isVisible, preferredWindow.isBreeMainWindow {
            return preferredWindow
        }
        if let keyWindow, keyWindow.isVisible, keyWindow.isBreeMainWindow {
            return keyWindow
        }
        if let mainWindow, mainWindow.isVisible, mainWindow.isBreeMainWindow {
            return mainWindow
        }
        return windows.first { $0.isVisible && $0.isBreeMainWindow }
    }
}

extension NSAlert {
    /// Presents this alert reliably from menu-tracking and ordinary AppKit contexts.
    ///
    /// The application is activated, then the alert is presented as a sheet on
    /// an eligible bree main window. If no host is available or the host already
    /// owns a sheet, presentation falls back to an application-modal session.
    ///
    /// - Parameters:
    ///   - presentingWindow: An explicit host window. When `nil`, the main bree
    ///     window is resolved by ``NSApplication/breeMainWindowForModalPresentation(preferring:)``.
    ///   - content: Structured alert copy whose user-sized details are bounded to
    ///     the presenting screen and made internally scrollable.
    ///   - willPresent: Invoked synchronously with the chosen presentation just
    ///     before the modal session begins.
    /// - Returns: The modal response selected by the user.
    @MainActor
    func runBreeModal(
        presentingWindow: NSWindow? = nil,
        content: BreeAlertContent? = nil,
        willPresent: ((BreeModalAlertPresentation) -> Void)? = nil
    ) -> NSApplication.ModalResponse {
        if NSApp.activationPolicy() == .regular {
            NSApp.activate(ignoringOtherApps: true)
        }

        let hostWindow = presentingWindow ?? NSApp.breeMainWindowForModalPresentation()
        if let content {
            content.apply(to: self, presentingWindow: hostWindow)
        } else if accessoryView == nil, !informativeText.isEmpty {
            BreeAlertContent(informativeText: informativeText)
                .apply(to: self, presentingWindow: hostWindow)
        }
        guard let hostWindow, hostWindow.attachedSheet == nil else {
            willPresent?(.appModal(hostWindowHadAttachedSheet: hostWindow?.attachedSheet != nil))
            return runModal()
        }

        willPresent?(.sheet(hostWindow))
        beginSheetModal(for: hostWindow) { result in
            NSApp.stopModal(withCode: result)
        }
        return NSApp.runModal(for: window)
    }
}
