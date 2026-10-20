import BREEAgentLaunch
import BreeFoundation
import BreeAgentJournal
import BreeSettings
import Foundation

/// Owns the app's agent message store and publishes its receipts on the
/// event bus (`bree events --category agent`).
///
/// It is also the one place the off switches are applied: the app-wide
/// `agentMessages.enabled` setting (read by the store on every send and
/// delivery) and per-surface or per-workspace opt-outs set through
/// ``setReceivingEnabled(_:scope:id:)``, which the socket, CLI and command
/// palette all call.
enum AgentMessageCenter {
    static let store: AgentMessageStore = {
        let store = AgentMessageStore(
            fileURL: defaultFileURL(),
            isEnabled: { AgentMessageCenter.isEnabled() },
            onChange: { change in
                let message = change.message
                BreeEventBus.shared.publish(
                    name: "agent.message.\(change.state.rawValue)",
                    category: "agent",
                    source: "agent.message",
                    workspaceId: message.recipientWorkspaceId,
                    surfaceId: message.recipientSurfaceId,
                    payload: [
                        "id": message.id,
                        "thread_id": message.threadId,
                        "sender_name": message.senderName,
                        "sender_surface_id": message.senderSurfaceId ?? NSNull(),
                        "state": change.state.rawValue,
                        "delivered_via": message.deliveredVia ?? NSNull(),
                        "failure_reason": message.failureReason ?? NSNull(),
                        "body_length": message.body.count,
                    ]
                )
            }
        )
        // Messages queued before a restart with the switch already off fail
        // now rather than waiting for their recipient to check in.
        store.failBlockedQueued()
        settingsObserver.start(store: store)
        return store
    }()

    private static let settingsObserver = AgentMessageEnabledObserver()

    /// Opens the store (journal replay, the launch sweep, maybe a compaction)
    /// on a background queue at launch, so the first command palette open or
    /// inbox read on main finds it ready. `static let` initialization runs
    /// once; a main-thread caller that races it waits for the same load.
    static func warmStoreOffMain() {
        DispatchQueue.global(qos: .utility).async {
            _ = store
        }
    }

    /// The app-wide switch, `agentMessages.enabled` in bree.json and
    /// Settings > Automation > Agent Messages.
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        AgentMessagesCatalogSection().enabled.value(in: defaults)
    }

    /// Turns messages for one surface or workspace off or on. Turning them
    /// off fails what was queued for it. The single entry point for the
    /// socket method, the CLI and the command palette. Pass
    /// ``openRecipientsIfAtCapacity()`` so a full store drops an opt-out for
    /// something already closed rather than one still open.
    @discardableResult
    static func setReceivingEnabled(
        _ enabled: Bool,
        scope: AgentMessageRecipientScope,
        id: UUID,
        openRecipients: AgentMessageOpenRecipients? = nil
    ) throws -> [AgentMessage] {
        try store.setReceivingEnabled(enabled, scope: scope, id: id.uuidString, openRecipients: openRecipients)
    }

    /// Every open surface and workspace, gathered only when the opt-out store
    /// is full; `nil` otherwise, which is almost always.
    @MainActor
    static func openRecipientsIfAtCapacity() -> AgentMessageOpenRecipients? {
        guard store.isAtOptOutCapacity, let app = AppDelegate.shared else { return nil }
        let workspaces = app.listMainWindowSummaries()
            .compactMap { app.tabManagerFor(windowId: $0.windowId) }
            .flatMap(\.tabs)
        return AgentMessageOpenRecipients(
            surfaceIds: Set(workspaces.flatMap { $0.panels.keys.map(\.uuidString) }),
            workspaceIds: Set(workspaces.map(\.id.uuidString))
        )
    }

    /// True when the surface or workspace turned messages off.
    static func isReceivingDisabled(scope: AgentMessageRecipientScope, id: UUID) -> Bool {
        store.isReceivingDisabled(scope: scope, id: id.uuidString)
    }

    /// `BREE_AGENT_MESSAGES_PATH`, else a per-install file next to the agent
    /// journal. In-memory under automated tests.
    static func defaultFileURL(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        isRunningUnderAutomatedTests: Bool = SessionRestorePolicy.isRunningUnderAutomatedTests()
    ) -> URL? {
        if let override = ProcessInfo.processInfo.environment["BREE_AGENT_MESSAGES_PATH"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        if isRunningUnderAutomatedTests {
            return nil
        }
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        let bundleID = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBundleID = bundleID?.isEmpty == false ? bundleID! : "com.bree.app"
        let safeBundleID = resolvedBundleID.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression
        )
        return appSupport
            .appendingPathComponent(BreeIdentity.current.applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("agent-messages-\(safeBundleID).jsonl", isDirectory: false)
    }

    static func payload(_ message: AgentMessage) -> [String: Any] {
        [
            "id": message.id,
            "thread_id": message.threadId,
            "sender_name": message.senderName,
            "sender_surface_id": message.senderSurfaceId ?? NSNull(),
            "sender_workspace_id": message.senderWorkspaceId ?? NSNull(),
            "recipient_surface_id": message.recipientSurfaceId,
            "recipient_workspace_id": message.recipientWorkspaceId ?? NSNull(),
            "body": message.body,
            "created_at": message.createdAt.timeIntervalSince1970,
            "in_reply_to": message.inReplyTo ?? NSNull(),
            "state": message.state.rawValue,
            "delivered_at": message.deliveredAt?.timeIntervalSince1970 ?? NSNull(),
            "delivered_via": message.deliveredVia ?? NSNull(),
            "read_at": message.readAt?.timeIntervalSince1970 ?? NSNull(),
            "failure_reason": message.failureReason ?? NSNull(),
        ]
    }
}

/// Fails every queued message when `agentMessages.enabled` turns off, from
/// Settings or a bree.json reload. Defaults change notifications are frequent,
/// so the sweep runs only on the on-to-off transition.
private final class AgentMessageEnabledObserver: @unchecked Sendable {
    // Lock justification: the notification arrives on whichever thread
    // changed defaults; the guarded state is one Bool and a token.
    private let lock = NSLock()
    private var wasEnabled = true
    private var token: (any NSObjectProtocol)?

    func start(store: AgentMessageStore) {
        lock.withLock {
            guard token == nil else { return }
            wasEnabled = AgentMessageCenter.isEnabled()
            token = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: nil,
                queue: nil
            ) { [weak self, weak store] _ in
                guard let self, let store else { return }
                self.defaultsDidChange(store: store)
            }
        }
    }

    private func defaultsDidChange(store: AgentMessageStore) {
        let enabled = AgentMessageCenter.isEnabled()
        let turnedOff = lock.withLock {
            defer { wasEnabled = enabled }
            return wasEnabled && !enabled
        }
        if turnedOff {
            store.failBlockedQueued()
        }
    }
}

// MARK: - File overlap notice

/// Tells an agent when another agent in the same checkout changed a file it
/// read or edited recently. Fed by the PostToolUse Read/Edit/Write events the
/// Feed already receives; the note travels as a normal agent message, so it
/// lands at the reader's next hook and is never typed into its prompt.
///
/// Event-driven: no timers. Entries expire lazily when the map is touched.
@MainActor
final class FileOverlapNotice {
    static let shared = FileOverlapNotice()

    static let maxEntries = 5_000
    static let accessWindow: TimeInterval = 30 * 60
    static let noteInterval: TimeInterval = 5 * 60

    private struct Access {
        let sessionId: String
        let surfaceId: String
        let workspaceId: String?
        var time: Date
    }

    private static let readTools: Set<String> = ["Read"]
    private static let writeTools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]

    /// "<worktree root>\0<absolute path>" -> accesses, one per session.
    private var accesses: [String: [Access]] = [:]
    /// "<reader session>\0<worktree root>\0<absolute path>" -> last note time.
    private var lastNote: [String: Date] = [:]

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        AgentMessagesCatalogSection().fileOverlapNotice.value(in: defaults)
    }

    func note(_ event: WorkstreamEvent, now: Date = Date()) {
        guard event.hookEventName == .postToolUse,
              event.isError != true,
              let tool = event.toolName,
              Self.readTools.contains(tool) || Self.writeTools.contains(tool),
              let surfaceId = event.surfaceId,
              let path = Self.filePath(from: event),
              Self.isEnabled(),
              let root = Self.worktreeRoot(forFile: path) else { return }

        let key = root + "\0" + path
        let isWrite = Self.writeTools.contains(tool)
        var list = (accesses[key] ?? []).filter { now.timeIntervalSince($0.time) < Self.accessWindow }

        if isWrite {
            let others = list.filter { $0.sessionId != event.sessionId && $0.surfaceId != surfaceId }
            if !others.isEmpty {
                let writerTitle = Self.workspaceTitle(surfaceId: surfaceId, workspaceId: event.workspaceId)
                let relative = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
                for reader in others {
                    let noteKey = reader.sessionId + "\0" + key
                    if let last = lastNote[noteKey], now.timeIntervalSince(last) < Self.noteInterval { continue }
                    lastNote[noteKey] = now
                    Self.send(
                        file: relative,
                        writer: writerTitle,
                        time: now,
                        to: reader.surfaceId,
                        workspaceId: reader.workspaceId
                    )
                }
            }
        }

        list.removeAll { $0.sessionId == event.sessionId }
        list.append(Access(sessionId: event.sessionId, surfaceId: surfaceId, workspaceId: event.workspaceId, time: now))
        accesses[key] = list
        if accesses.count > Self.maxEntries || lastNote.count > Self.maxEntries { prune(now: now) }
    }

    /// Drops expired entries, then the oldest tenth if the map is still full.
    private func prune(now: Date) {
        accesses = accesses.compactMapValues { list in
            let live = list.filter { now.timeIntervalSince($0.time) < Self.accessWindow }
            return live.isEmpty ? nil : live
        }
        lastNote = lastNote.filter { now.timeIntervalSince($0.value) < Self.noteInterval }
        for (cap, drop) in [(accesses.count, true), (lastNote.count, false)] where cap > Self.maxEntries {
            if drop {
                let oldest = accesses.sorted { ($0.value.last?.time ?? .distantPast) < ($1.value.last?.time ?? .distantPast) }
                oldest.prefix(cap / 10).forEach { accesses[$0.key] = nil }
            } else {
                lastNote.sorted { $0.value < $1.value }.prefix(cap / 10).forEach { lastNote[$0.key] = nil }
            }
        }
    }

    // MARK: - Helpers

    private static func filePath(from event: WorkstreamEvent) -> String? {
        guard let data = event.toolInputJSON?.data(using: .utf8),
              let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = (input["file_path"] ?? input["notebook_path"]) as? String,
              raw.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: raw)
        // Resolve symlinks on the directory only, so /tmp and /private/tmp agree
        // and a file that was just deleted still maps to a key.
        return url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent).path
    }

    /// Nearest ancestor holding a `.git` entry (a directory, or the file a
    /// linked worktree uses), so two worktrees of one repo never share a key.
    private static func worktreeRoot(forFile path: String) -> String? {
        var dir = (path as NSString).deletingLastPathComponent
        let fm = FileManager.default
        while dir.count > 1 {
            if fm.fileExists(atPath: dir + "/.git") { return dir }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }

    private static func workspaceTitle(surfaceId: String, workspaceId: String?) -> String {
        let fallback = "another agent"
        guard let app = AppDelegate.shared, let panel = UUID(uuidString: surfaceId) else { return fallback }
        let title = app.workspaceContainingPanel(
            panelId: panel,
            preferredWorkspaceId: workspaceId.flatMap(UUID.init(uuidString:))
        )?.workspace.title ?? ""
        let clean = String(title.unicodeScalars.filter { !$0.properties.generalCategory.isControl }.map(Character.init))
            .trimmingCharacters(in: .whitespaces)
        return clean.isEmpty ? fallback : String(clean.prefix(64))
    }

    private static func send(file: String, writer: String, time: Date, to surfaceId: String, workspaceId: String?) {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        let clock = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        let cleanFile = String(file.unicodeScalars.filter { !$0.properties.generalCategory.isControl }.map(Character.init))
        // Agent-facing text, not localized.
        let draft = AgentMessageDraft(
            senderName: "bree",
            recipientSurfaceId: surfaceId,
            recipientWorkspaceId: workspaceId,
            body: "\(cleanFile) was changed by \(writer) at \(clock); re-read before editing"
        )
        // The journal write is file I/O; keep it off the main actor.
        DispatchQueue.global(qos: .utility).async {
            _ = try? AgentMessageCenter.store.append(draft)
        }
    }
}

private extension Unicode.GeneralCategory {
    var isControl: Bool { self == .control || self == .lineSeparator || self == .paragraphSeparator }
}
