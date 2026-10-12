import AppKit

/// Pop-up list behind the "Open Pinned File…" palette command: the pinned
/// files of the workspace's project. Choosing one opens it through the Quick
/// View file-open path, the same as clicking a file in the Files sidebar.
@MainActor
enum PinnedFilesMenu {
    @MainActor
    private final class Target: NSObject {
        let workspace: Workspace
        init(workspace: Workspace) { self.workspace = workspace }

        @objc func open(_ sender: NSMenuItem) {
            guard let path = sender.representedObject as? String else { return }
            QuickViewResource.file(path: path).open(from: workspace)
        }
    }

    static func present(for workspace: Workspace, in window: NSWindow?) {
        guard let contentView = window?.contentView else {
            NSSound.beep()
            return
        }
        let root = PinnedFilesStore.projectRoot(forDirectory: workspace.currentDirectory)
        let pins = PinnedFilesStore().pins(forRoot: root)
        let target = Target(workspace: workspace)
        let menu = NSMenu()
        if pins.isEmpty {
            let empty = NSMenuItem(
                title: String(localized: "fileExplorer.pinned.none", defaultValue: "No Pinned Files"),
                action: nil,
                keyEquivalent: ""
            )
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for relative in pins {
            let absolute = PinnedFilesStore.absolutePath(for: relative, root: root)
            let exists = FileManager.default.fileExists(atPath: absolute)
            let item = NSMenuItem(
                title: relative,
                action: exists ? #selector(Target.open(_:)) : nil,
                keyEquivalent: ""
            )
            item.target = target
            item.representedObject = absolute
            item.isEnabled = exists
            if !exists {
                item.toolTip = String(localized: "fileExplorer.pinned.missing", defaultValue: "Missing")
            }
            menu.addItem(item)
        }
        // popUp blocks until the menu closes, so `target` outlives the selection.
        let bounds = contentView.bounds
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: bounds.midX - 120, y: bounds.maxY - bounds.height * 0.3),
            in: contentView
        )
        withExtendedLifetime(target) {}
    }
}
