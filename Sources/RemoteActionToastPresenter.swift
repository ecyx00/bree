import AppKit
import Darwin

/// Shows what a socket client did to the UI as one non-interactive pill per
/// window, top-right of the content area. Never receives argument values:
/// only a client name, an action kind and a workspace title.
@MainActor
final class RemoteActionToastPresenter {
    static let shared = RemoteActionToastPresenter()
    /// Bree-only setting (not bree.json); on unless explicitly disabled.
    static let enabledDefaultsKey = "bree.remoteActionToast.enabled"

    @MainActor
    private final class WindowToast {
        var coalescer = RemoteActionToastCoalescer()
        let container = PassthroughWindowOverlayContainerView(frame: .zero)
        let badge = FileDropHintBadgeView(frame: .zero)
        var hideTask: Task<Void, Never>?
    }

    private var toasts: [ObjectIdentifier: WindowToast] = [:]

    nonisolated static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledDefaultsKey) as? Bool ?? true
    }

    /// Entry from the socket choke point; safe from any thread.
    /// `workspaceId` and `surfaceId` are the ids the request carried, nothing else.
    nonisolated static func noteSocketAction(
        method: String,
        workspaceId: String?,
        surfaceId: String?,
        clientPid: pid_t
    ) {
        guard isEnabled, let kind = RemoteActionKind.kind(forMethod: method) else { return }
        let client = RemoteActionClientName.resolve(
            pid: clientPid,
            appPid: getpid(),
            nameOf: processName(_:),
            parentOf: parentPid(_:)
        )
        Task { @MainActor in
            shared.present(client: client, kind: kind, workspaceId: workspaceId, surfaceId: surfaceId)
        }
    }

    private nonisolated static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let name = String(cString: buffer)
        // Some agents run from a versioned binary (".../claude/versions/2.1.292"):
        // name them after the nearest directory that is not a version or layout folder.
        guard name.first?.isNumber == true else { return name }
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 else { return name }
        let skipped: Set<String> = ["versions", "bin", "release", "current", "latest", "libexec", "lib"]
        let parts = String(cString: pathBuffer).split(separator: "/").map(String.init)
        return parts.dropLast().last { !skipped.contains($0) && $0.first?.isNumber != true } ?? name
    }

    private nonisolated static func parentPid(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    func present(client: String, kind: RemoteActionKind, workspaceId: String?, surfaceId: String?) {
        let (window, title) = resolveWindowAndTitle(workspaceId: workspaceId, surfaceId: surfaceId)
        guard let window, let content = window.contentView else { return }
        let key = ObjectIdentifier(window)
        let toast = toasts[key] ?? WindowToast()
        toasts[key] = toast
        let entry = toast.coalescer.record(client: client, kind: kind, target: title, now: Date())
        if toast.container.superview !== content {
            toast.container.removeFromSuperview()
            toast.container.frame = content.bounds
            toast.container.autoresizingMask = [.width, .height]
            toast.container.addSubview(toast.badge)
            content.addSubview(toast.container, positioned: .above, relativeTo: nil)
        } else if content.subviews.last !== toast.container {
            content.addSubview(toast.container, positioned: .above, relativeTo: nil)
        }
        let bounds = toast.container.bounds
        // Sidebar visible: bottom of the left sidebar at its width minus margins, never over pane
        // content. Collapsed: the titlebar row right of the leading controls, over the tab strip.
        let context = AppDelegate.shared?.mainWindowContexts.values
            .first { AppDelegate.shared?.resolvedWindow(for: $0) === window }
        let anchor: CGRect
        if let sidebar = context?.sidebarState, sidebar.isVisible {
            let width = bounds.width < ContentView.narrowSidebarWindowWidth ? ContentView.narrowSidebarWidth : sidebar.persistedWidth
            anchor = CGRect(x: bounds.minX, y: bounds.minY + 8, width: width, height: 28)
        } else {
            let barHeight = WindowChromeMetrics.appTitlebarHeight
            anchor = CGRect(x: 142, y: bounds.maxY - barHeight, width: 236, height: barHeight)
        }
        toast.badge.show(text: entry.text, centeredIn: anchor, clippedTo: bounds, minWidth: 0)
        // Reduce Motion: the badge only fades, it never slides, so nothing more to disable.
        toast.hideTask?.cancel()
        toast.hideTask = Task { @MainActor [weak toast] in
            try? await Task.sleep(for: .seconds(RemoteActionToastCoalescer.visibleSeconds))
            guard !Task.isCancelled, let toast else { return }
            toast.badge.hideImmediately()
        }
    }

    private func resolveWindowAndTitle(workspaceId: String?, surfaceId: String?) -> (NSWindow?, String?) {
        let contexts = AppDelegate.shared?.mainWindowContexts.values.map { $0 } ?? []
        let workspaceUUID = workspaceId.flatMap(UUID.init(uuidString:))
        let surfaceUUID = surfaceId.flatMap(UUID.init(uuidString:))
        for context in contexts {
            for workspace in context.tabManager.tabs {
                if workspace.id == workspaceUUID || (surfaceUUID.map { workspace.panels[$0] != nil } ?? false) {
                    return (AppDelegate.shared?.resolvedWindow(for: context), workspace.title)
                }
            }
        }
        let fallback = NSApp.keyWindow ?? NSApp.mainWindow
        for context in contexts {
            guard let window = AppDelegate.shared?.resolvedWindow(for: context) else { continue }
            if window === fallback {
                return (window, context.tabManager.selectedWorkspace?.title)
            }
        }
        if let context = contexts.first {
            return (AppDelegate.shared?.resolvedWindow(for: context), context.tabManager.selectedWorkspace?.title)
        }
        return (nil, nil)
    }
}
