import Foundation

/// One-line project pulse under a workspace name, e.g.
/// `main · 3 changed · Codex waiting · :3000`. Each part appears only when it exists.
enum SidebarWorkspacePulse {
    static let separator = " · "
    /// Ports shown before the rest are dropped; the line is one row.
    static let maxPorts = 3

    /// The inputs of one Pulse line. The snapshot keeps these rather than the
    /// finished string so the time in the current state is formatted at render
    /// time and keeps counting without rebuilding the snapshot.
    struct Input: Equatable, Sendable {
        var branch: String?
        var changedFileCount: Int?
        var agentKind: SidebarCompactStatusGlyph.Kind?
        var agentName: String?
        /// When the agent entered its current state.
        var agentSince: Date?
        var ports: [Int]

        func line(now: Date, changedFileCountOverride: Int? = nil) -> String? {
            SidebarWorkspacePulse.line(
                branch: branch,
                changedFileCount: changedFileCountOverride ?? changedFileCount,
                changedWhileAway: changedFileCountOverride != nil,
                agentKind: agentKind,
                agentName: agentName,
                agentSince: agentSince,
                now: now,
                ports: ports
            )
        }
    }

    /// Joins the parts that exist; `nil` when none do. With `agentSince` the
    /// agent part ends in the time in that state: `Claude waiting · 12m`.
    static func line(
        branch: String?,
        changedFileCount: Int?,
        changedWhileAway: Bool = false,
        agentKind: SidebarCompactStatusGlyph.Kind?,
        agentName: String? = nil,
        agentSince: Date? = nil,
        now: Date = Date(),
        ports: [Int]
    ) -> String? {
        var parts: [String] = []
        if let branch, !branch.isEmpty { parts.append(branch) }
        if let changedFileCount, changedFileCount > 0 {
            parts.append(String(
                format: changedWhileAway
                    ? String(localized: "sidebar.pulse.changedAway", defaultValue: "%lld changed while away")
                    : String(localized: "sidebar.pulse.changed", defaultValue: "%lld changed"),
                Int64(changedFileCount)
            ))
        }
        if let word = agentWord(for: agentKind) {
            parts.append([agentName, word].compactMap { $0 }.joined(separator: " "))
            if let agentSince {
                parts.append(AttentionRanking.relativeLabel(
                    sinceMs: Int64(agentSince.timeIntervalSince1970 * 1000),
                    nowMs: Int64(now.timeIntervalSince1970 * 1000)
                ))
            }
        }
        if !ports.isEmpty {
            parts.append(ports.prefix(maxPorts).map(SidebarPortDisplayText.label(for:)).joined(separator: " "))
        }
        return parts.isEmpty ? nil : parts.joined(separator: separator)
    }

    /// Resource-guard parts: `3.1 GB · 140%` while high, `paused` while stopped.
    /// `nil` when neither applies, so an idle workspace shows nothing extra.
    static func resourceText(_ state: ResourceGuardWorkspaceState?) -> String? {
        guard let state else { return nil }
        var parts: [String] = []
        if state.isHigh {
            let gb = Double(state.memoryBytes) / (1024 * 1024 * 1024)
            parts.append(gb >= 1
                ? String(format: "%.1f GB", gb)
                : String(format: "%lld MB", Int64(state.memoryBytes / (1024 * 1024))))
            parts.append(String(format: "%.0f%%", state.cpuPercent))
        }
        if state.isPaused {
            parts.append(String(localized: "sidebar.pulse.paused", defaultValue: "paused"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: separator)
    }

    /// One short word per agent state; states that say nothing useful return `nil`.
    static func agentWord(for kind: SidebarCompactStatusGlyph.Kind?) -> String? {
        switch kind {
        case .running, .subagents:
            return String(localized: "sidebar.pulse.agent.running", defaultValue: "running")
        case .needsInput:
            return String(localized: "sidebar.pulse.agent.needsInput", defaultValue: "needs input")
        case .waiting:
            return String(localized: "sidebar.pulse.agent.waiting", defaultValue: "waiting")
        case .error:
            return String(localized: "sidebar.pulse.agent.failed", defaultValue: "failed")
        case .idle:
            return String(localized: "sidebar.pulse.agent.done", defaultValue: "done")
        default:
            return nil
        }
    }
}
