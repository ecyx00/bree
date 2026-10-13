import AppKit
import Combine
import SwiftUI

/// The Board as a titlebar popover, opened like Architecture and Wiki. One at a time, in one window.
/// Sampling of outside sessions runs only while it is open.
@MainActor
final class BoardPopoverController: NSObject {
    static let shared = BoardPopoverController()

    private static let width: CGFloat = 520

    private var session: TabBarPopoverSession?
    private weak var parentWindow: NSWindow?
    private var model: BoardModel?
    private var sizeObserver: AnyCancellable?
    private var lastTransientCloseAt: CFTimeInterval = 0

    func isShowing(in window: NSWindow?) -> Bool {
        session != nil && parentWindow === window
    }

    func closeAllAttached() {
        if session?.isDetached == false { session?.close() }
    }

    func toggle(from workspace: Workspace) {
        guard let parent = workspace.owningTabManager.flatMap({ AppDelegate.shared?.mainWindowContext(for: $0) })?.window else {
            NSSound.beep()
            return
        }
        if let session {
            session.close()
            return
        }
        if let event = NSApp.currentEvent, [.leftMouseDown, .leftMouseUp].contains(event.type),
           CACurrentMediaTime() - lastTransientCloseAt < 0.3 {
            return
        }
        BreeOverlays.closeOthers(than: .board)
        let model = BoardModel()
        guard let session = TabBarPopoverSession(
            workspace: workspace,
            parent: parent,
            slot: 0,
            sizeName: "board",
            preferredSize: { maxWidth, maxHeight in
                NSSize(width: min(Self.width, max(maxWidth, 280)), height: min(320, max(maxHeight, 120)))
            },
            content: BoardView(model: model).breeFontMagnificationEnvironment()
        ) else { return }
        model.close = { [weak session] in session?.close() }
        session.onWillClose = { [weak self] in self?.lastTransientCloseAt = CACurrentMediaTime() }
        session.onClosed = { [weak self] in
            self?.model?.stop()
            self?.session = nil
            self?.model = nil
            self?.sizeObserver = nil
            self?.parentWindow = nil
            NotificationCenter.default.post(name: .surfaceTabBarDynamicStateDidChange, object: nil)
        }
        // Height follows the content; the session limits it to the room and the view scrolls past that.
        sizeObserver = model.$contentHeight.removeDuplicates().sink { [weak session] height in
            guard height > 0 else { return }
            DispatchQueue.main.async { session?.setSurfaceSize(NSSize(width: Self.width, height: height)) }
        }
        self.session = session
        self.model = model
        parentWindow = parent
        model.start()
        session.show()
        NotificationCenter.default.post(name: .surfaceTabBarDynamicStateDidChange, object: nil)
    }
}
