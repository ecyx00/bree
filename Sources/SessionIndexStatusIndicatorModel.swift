import BreeFoundation
import SwiftUI

/// Immutable presentation state for the status circle shown beside a Vault
/// session. The private state enum keeps the active flag and accessibility
/// label derived from one source instead of allowing contradictory values.
struct SessionIndexStatusIndicatorModel: Equatable, Sendable {
    private enum State: Equatable, Sendable {
        case activeInPane
        case active
        case inactive
        case agent(AttentionState)
    }

    private let state: State

    private init(state: State) {
        self.state = state
    }

    var isActive: Bool {
        switch state {
        case .activeInPane, .active, .agent:
            return true
        case .inactive:
            return false
        }
    }

    var label: String {
        switch state {
        case .activeInPane:
            return String(
                localized: "sessionIndex.status.activeInPane",
                defaultValue: "Active in pane"
            )
        case .active:
            return String(
                localized: "sessionIndex.status.activeIndicator",
                defaultValue: "Active"
            )
        case .inactive:
            return String(
                localized: "sessionIndex.status.inactiveIndicator",
                defaultValue: "Inactive"
            )
        case .agent(let agent):
            return AttentionStyle.word(for: agent) ?? ""
        }
    }

    func color(palette: BreeChromePalette) -> Color {
        if case .agent(let agent) = state { return AttentionStyle.symbol(for: agent, palette: palette).tint }
        return isActive ? palette.signalSuccess : palette.glyphTertiary
    }

    /// Active sessions are a filled circle, inactive history a ring, so the
    /// state does not depend on colour alone.
    var isFilled: Bool { isActive }

    /// The Vault circle represents a session that is active and focusable in
    /// this bree window. The parent supplies this flag only for panes whose
    /// shell reports a foreground command, so a pane that has returned to its
    /// shell cannot remain green. A process running in another terminal (or
    /// one that cannot be mapped to a pane) remains gray here.
    nonisolated static func make(
        isInPane: Bool,
        liveStatus: VaultSessionLiveStatus?,
        agentState: AttentionState? = nil
    ) -> SessionIndexStatusIndicatorModel {
        _ = liveStatus
        if let agentState { return SessionIndexStatusIndicatorModel(state: .agent(agentState)) }
        return SessionIndexStatusIndicatorModel(
            state: isInPane ? .activeInPane : .inactive
        )
    }
}
