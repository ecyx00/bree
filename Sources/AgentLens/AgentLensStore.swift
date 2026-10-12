import CMUXAgentLaunch
import CmuxAgentChat
import CmuxFoundation
import Foundation

/// Live Claude Code sessions for the Sessions tab "Live" section.
///
/// Hook events (already accepted by the feed pipeline, delivered on the main
/// actor through `.workstreamEventReceived`) go through ``AgentLensReducer``.
/// Usage (context, cost) is pushed in by `SidebarAgentUsageCoordinator`, which
/// owns the off-main transcript sampler; this store performs no file I/O.
@MainActor
final class AgentLensStore: ObservableObject {
    static let shared = AgentLensStore()

    /// Sorted for display; empty means the section is absent.
    @Published private(set) var cards: [AgentLensCard] = []

    /// Files of sessions that ended, per workspace, until a new session starts there
    /// (the "Edited by Claude" shelf must outlive the session). In memory only.
    struct EndedSession: Equatable, Sendable {
        let files: [String]
        let at: Date
    }
    @Published private(set) var endedSessions: [UUID: [EndedSession]] = [:]

    static let maxCards = 32
    /// Idle cards with no event for this long are dropped on the next event
    /// (covers a Claude killed without `SessionEnd`).
    static let idleExpiry: TimeInterval = 4 * 3600

    private var byID: [String: AgentLensCard] = [:]
    private var usageByID: [String: AgentLensUsage] = [:]
    private var observation: Task<Void, Never>?
    private var cacheRequests: [String: Date] = [:]
    private var cacheMTime: Date?
    private var cacheLastRead = Date.distantPast
    private var cacheReadPending = false
    static let cacheReadInterval: TimeInterval = 30

    init() {}

    func start() {
        guard observation == nil else { return }
        observation = Task { @MainActor [weak self] in
            for await notification in NotificationCenter.default.notifications(named: .workstreamEventReceived) {
                guard !Task.isCancelled else { return }
                guard let event = notification.object as? WorkstreamEvent else { continue }
                self?.note(event)
            }
        }
    }

    func note(_ event: WorkstreamEvent) {
        guard event.source == "claude" else { return }
        let previous = byID[event.sessionId]
        if let card = AgentLensReducer.reduce(previous, event: event) {
            if previous == nil { endedSessions.removeValue(forKey: card.workspaceID) }
            byID[event.sessionId] = card
        } else {
            if let previous, !previous.files.isEmpty {
                endedSessions[previous.workspaceID, default: []].insert(
                    EndedSession(files: previous.files, at: event.receivedAt), at: 0
                )
            }
            byID.removeValue(forKey: event.sessionId)
            usageByID.removeValue(forKey: event.sessionId)
        }
        prune(now: event.receivedAt)
        publish()
        switch event.hookEventName {
        case .userPromptSubmit: refreshCache(delay: 0)
        case .stop: refreshCache(delay: 2)   // the mod stamps request:<sid> at turn end
        default: break
        }
    }

    /// Reads the cache-warm store off the main actor, at most every 30 s
    /// (a throttled request becomes one trailing read), only while cards exist.
    private func refreshCache(delay: TimeInterval) {
        guard !byID.isEmpty, !cacheReadPending else { return }
        let wait = max(delay, Self.cacheReadInterval - Date().timeIntervalSince(cacheLastRead))
        cacheReadPending = true
        let known = cacheMTime
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, wait)) { [weak self] in
            let result = AgentLensCacheStore.read(ifChangedSince: known)
            DispatchQueue.main.async {
                guard let self else { return }
                self.cacheReadPending = false
                self.cacheLastRead = Date()
                guard let result else { return }
#if DEBUG
                cmuxDebugLog("agentLens.cache read sids=\(result.requests.keys.map { String($0.prefix(8)) }) cards=\(self.byID.keys.map { String($0.prefix(8)) })")
#endif
                self.cacheMTime = result.mtime
                self.cacheRequests = result.requests
                self.publish()
            }
        }
    }

    func noteUsage(sessionID: String, snapshot: AgentUsageSnapshot) {
        // The card always exists first (the sample is scheduled by its event);
        // a late sample for an ended session must not resurrect state.
        guard byID[sessionID] != nil else { return }
        usageByID[sessionID] = AgentLensUsage(
            contextFraction: snapshot.contextFraction,
            costUSD: snapshot.estimatedCost?.usd,
            costIsLowerBound: snapshot.estimatedCost?.isLowerBound ?? false
        )
        publish()
    }

    private func prune(now: Date) {
        for (id, card) in byID where card.state == .idle && now.timeIntervalSince(card.lastEventAt) > Self.idleExpiry {
            byID.removeValue(forKey: id)
            usageByID.removeValue(forKey: id)
        }
        while byID.count > Self.maxCards,
              let oldest = byID.min(by: { $0.value.lastEventAt < $1.value.lastEventAt })?.key {
            byID.removeValue(forKey: oldest)
            usageByID.removeValue(forKey: oldest)
        }
    }

    private func publish() {
        let sorted = byID.values.map { card -> AgentLensCard in
            var card = card
            card.usage = usageByID[card.id]
            // Card ids are Feed workstream ids; the mod keys by the raw Claude session id.
            card.cacheRequestAt = cacheRequests[FeedWorkstreamIdentifier(rawValue: card.id)?.sessionID ?? card.id]
            return card
        }.sorted {
            if $0.state != $1.state { return $0.state < $1.state }
            if $0.lastEventAt != $1.lastEventAt { return $0.lastEventAt > $1.lastEventAt }
            return $0.id < $1.id
        }
        if sorted != cards { cards = sorted }
    }
}


/// Read-only view of the cache-warm Claude Code mod's JSON store
/// (`~/.claude/plugins/store/cache-warm_*.json`, one flat object, keys
/// `request:<sid>` = ms epoch of the last API request, `last:<sid>.at`).
/// Blocking file I/O: call from a GCD queue only.
enum AgentLensCacheStore {
    /// Anthropic prompt-cache TTL the mod assumes (`TTL_MS = HOUR`).
    static let ttl: TimeInterval = 3600

    struct Result {
        let mtime: Date
        let requests: [String: Date]
    }

    /// - Returns: `nil` when the file is missing, unreadable or unchanged since `known`.
    static func read(ifChangedSince known: Date?, directory: URL? = nil) -> Result? {
        let dir = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/plugins/store", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
              let name = names.sorted().first(where: { $0.hasPrefix("cache-warm_") && $0.hasSuffix(".json") })
        else { return nil }
        let url = dir.appendingPathComponent(name)
        guard let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              mtime != known,
              let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var requests: [String: Date] = [:]
        for (key, value) in object {
            if key.hasPrefix("request:"), let ms = (value as? NSNumber)?.doubleValue {
                let sid = String(key.dropFirst("request:".count))
                requests[sid] = max(requests[sid] ?? .distantPast, Date(timeIntervalSince1970: ms / 1000))
            } else if key.hasPrefix("last:"), let at = (value as? [String: Any])?["at"] as? NSNumber {
                let sid = String(key.dropFirst("last:".count))
                requests[sid] = max(requests[sid] ?? .distantPast, Date(timeIntervalSince1970: at.doubleValue / 1000))
            }
        }
        return Result(mtime: mtime, requests: requests)
    }

    /// Whole minutes of cache left, floored at 0.
    static func minutesLeft(requestAt: Date, now: Date) -> Int {
        max(0, Int((ttl - now.timeIntervalSince(requestAt)) / 60))
    }
}
