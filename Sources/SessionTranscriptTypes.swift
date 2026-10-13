import BreeFoundation
import SwiftUI

struct SessionTranscriptTurn: Identifiable, Equatable, Sendable {
    let id: Int
    let role: SessionTranscriptRole
    let text: String
}

enum SessionTranscriptRole: Equatable, Sendable {
    case user
    case assistant
    case system
    case tool
    case event

    var label: String {
        switch self {
        case .user:
            return String(localized: "sessionIndex.preview.role.user", defaultValue: "You")
        case .assistant:
            return String(localized: "sessionIndex.preview.role.assistant", defaultValue: "Agent")
        case .system:
            return String(localized: "sessionIndex.preview.role.system", defaultValue: "System")
        case .tool:
            return String(localized: "sessionIndex.preview.role.tool", defaultValue: "Tool")
        case .event:
            return String(localized: "sessionIndex.preview.role.event", defaultValue: "Event")
        }
    }

    func foregroundColor(palette: BreeChromePalette) -> Color {
        switch self {
        case .user: return palette.activeIndicator
        case .assistant: return palette.signalSuccess
        case .system: return palette.textSecondary
        case .tool: return palette.textSecondary
        case .event: return palette.textSecondary
        }
    }

    func backgroundColor(palette: BreeChromePalette) -> Color {
        switch self {
        case .user: return palette.activeIndicator.opacity(0.05)
        case .assistant: return palette.signalSuccess.opacity(0.05)
        case .system: return palette.hoverFill.opacity(0.4)
        case .tool: return palette.textSecondary.opacity(0.05)
        case .event: return palette.hoverFill.opacity(0.4)
        }
    }

    /// Tool and system output is shown in the mono role; the rest in body text.
    var usesMonospacedBody: Bool {
        switch self {
        case .tool, .system:
            return true
        case .user, .assistant, .event:
            return false
        }
    }
}
