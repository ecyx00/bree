import Foundation

/// What a socket client did to the UI. Only methods that change what the
/// person sees are listed; read and unknown methods stay quiet (agents poll a lot).
enum RemoteActionKind: String, CaseIterable, Sendable {
    case typed
    case focused
    case created
    case closed
    case renamed
    case split
    case moved
    case browsed

    /// Allowlist, method name to action. Fail quiet: anything absent never toasts.
    static let methods: [String: RemoteActionKind] = [
        "surface.send_text": .typed,
        "surface.send_key": .typed,
        "surface.focus": .focused,
        "pane.focus": .focused,
        "window.focus": .focused,
        "workspace.select": .focused,
        "workspace.next": .focused,
        "workspace.previous": .focused,
        "workspace.last": .focused,
        "window.create": .created,
        "workspace.create": .created,
        "surface.create": .created,
        "pane.create": .created,
        "window.close": .closed,
        "workspace.close": .closed,
        "surface.close": .closed,
        "workspace.rename": .renamed,
        "surface.split": .split,
        "surface.split_off": .split,
        "browser.open_split": .split,
        "surface.move": .moved,
        "workspace.move": .moved,
        "workspace.move_to_window": .moved,
        "workspace.reorder": .moved,
        "workspace.reorder_many": .moved,
        "pane.swap": .moved,
        "pane.break": .moved,
        "pane.join": .moved,
        "browser.navigate": .browsed,
        "browser.back": .browsed,
        "browser.forward": .browsed,
        "browser.reload": .browsed,
    ]

    static func kind(forMethod method: String) -> RemoteActionKind? { methods[method] }

    /// "typed into api". The target is a workspace title, never an argument value.
    func phrase(target: String?) -> String {
        let name = target.flatMap { $0.isEmpty ? nil : $0 }
        switch self {
        case .typed:
            return name.map { String(format: String(localized: "remoteToast.typed", defaultValue: "typed into %@"), $0) }
                ?? String(localized: "remoteToast.typed.generic", defaultValue: "typed into a pane")
        case .focused:
            return name.map { String(format: String(localized: "remoteToast.focused", defaultValue: "focused %@"), $0) }
                ?? String(localized: "remoteToast.focused.generic", defaultValue: "moved focus")
        case .created:
            return name.map { String(format: String(localized: "remoteToast.created", defaultValue: "created in %@"), $0) }
                ?? String(localized: "remoteToast.created.generic", defaultValue: "created something")
        case .closed:
            return name.map { String(format: String(localized: "remoteToast.closed", defaultValue: "closed in %@"), $0) }
                ?? String(localized: "remoteToast.closed.generic", defaultValue: "closed something")
        case .renamed:
            return name.map { String(format: String(localized: "remoteToast.renamed", defaultValue: "renamed %@"), $0) }
                ?? String(localized: "remoteToast.renamed.generic", defaultValue: "renamed a workspace")
        case .split:
            return name.map { String(format: String(localized: "remoteToast.split", defaultValue: "split %@"), $0) }
                ?? String(localized: "remoteToast.split.generic", defaultValue: "split a pane")
        case .moved:
            return name.map { String(format: String(localized: "remoteToast.moved", defaultValue: "moved %@"), $0) }
                ?? String(localized: "remoteToast.moved.generic", defaultValue: "moved something")
        case .browsed:
            return name.map { String(format: String(localized: "remoteToast.browsed", defaultValue: "navigated the browser in %@"), $0) }
                ?? String(localized: "remoteToast.browsed.generic", defaultValue: "navigated the browser")
        }
    }
}

/// One pill's content. `count` > 1 renders as "+N".
struct RemoteActionToastEntry: Equatable, Sendable {
    let client: String
    let kind: RemoteActionKind
    var target: String?
    var count: Int
    var expiresAt: Date

    var text: String {
        let base = "\(client) · \(kind.phrase(target: target))"
        return count > 1 ? "\(base) +\(count - 1)" : base
    }
}

/// Pure coalescing: the same client and action inside the visible window
/// extend one pill as "+N"; anything else replaces it.
struct RemoteActionToastCoalescer: Sendable {
    static let visibleSeconds: TimeInterval = 2.5

    private(set) var current: RemoteActionToastEntry?

    mutating func record(
        client: String,
        kind: RemoteActionKind,
        target: String?,
        now: Date
    ) -> RemoteActionToastEntry {
        let expires = now.addingTimeInterval(Self.visibleSeconds)
        if var entry = current, entry.expiresAt > now, entry.client == client, entry.kind == kind {
            entry.count += 1
            entry.target = target
            entry.expiresAt = expires
            current = entry
            return entry
        }
        let entry = RemoteActionToastEntry(client: client, kind: kind, target: target, count: 1, expiresAt: expires)
        current = entry
        return entry
    }

    /// Whether a pill should still be on screen.
    func isVisible(now: Date) -> Bool {
        (current?.expiresAt ?? .distantPast) > now
    }
}

/// Names the process behind a socket peer. The peer is usually the `bree` CLI
/// run by an agent's shell tool, so walk up past the CLI and shells to the agent.
enum RemoteActionClientName {
    static let fallback = "bree"
    private static let transparent: Set<String> = [
        "bree", "bree", "sh", "bash", "zsh", "fish", "dash", "ksh", "env", "sudo", "login", "script", "timeout",
    ]

    static func resolve(
        pid: pid_t?,
        appPid: pid_t,
        nameOf: (pid_t) -> String?,
        parentOf: (pid_t) -> pid_t?,
        maxDepth: Int = 8
    ) -> String {
        var current = pid
        var depth = 0
        while let candidate = current, candidate > 1, candidate != appPid, depth < maxDepth {
            if let name = nameOf(candidate), !name.isEmpty, !transparent.contains(name.lowercased()) {
                return name
            }
            current = parentOf(candidate)
            depth += 1
        }
        return fallback
    }
}
