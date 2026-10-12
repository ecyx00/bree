import Foundation

/// The command (or file) an agent is asking permission for, reduced to what the
/// Attention Center shows. It stays in app memory and is never put in a
/// notification: commands can embed credentials.
struct AttentionPendingTool: Equatable, Sendable {
    let toolName: String
    /// Shell command, or the empty string when the tool has none.
    let command: String
    /// Target file for edit/write tools, `nil` otherwise.
    let filePath: String?

    /// What the row prints under the title; the command wins over the file path.
    var summary: String? {
        if let line = AttentionRanking.oneLine(command, limit: 300) { return line }
        return filePath.flatMap { AttentionRanking.oneLine($0, limit: 300) }
    }

    /// Reads the `toolInputJSON` of a Feed permission request. Unparseable or
    /// empty input yields `nil`, so no row line is invented.
    static func parse(toolName: String, toolInputJSON: String) -> AttentionPendingTool? {
        guard let data = toolInputJSON.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        var command = ""
        if let text = object["command"] as? String {
            command = text
        } else if let parts = object["command"] as? [String] {
            command = parts.joined(separator: " ")
        }
        let filePath = (object["file_path"] as? String) ?? (object["path"] as? String)
        guard !command.isEmpty || filePath != nil else { return nil }
        return AttentionPendingTool(toolName: toolName, command: command, filePath: filePath)
    }
}

/// Dangerous-command rules as a pure table. Order is severity: the first match
/// names the note. Unknown commands match nothing; the table never invents risk.
enum AttentionRisk: String, CaseIterable, Sendable {
    case recursiveDelete
    case forcePush
    case resetHard
    case cleanForce
    case discardChanges
    case recursivePermissions
    case sudo
    case pipeToShell
    case diskWrite
    case sqlDestructive
    case forceKill
    case sensitiveWrite

    private static let shellRules: [(AttentionRisk, String)] = [
        (.recursiveDelete, #"\brm\s+([^;&|]*\s)?(-[a-z]*r[a-z]*|--recursive)(\s|$)"#),
        (.forcePush, #"\bgit\s+([^;&|]*\s)?push\b[^;&|]*(\s(--force|--force-with-lease|-f)(\s|=|$)|\s\+[\w/.:-]+)"#),
        (.resetHard, #"\bgit\s+([^;&|]*\s)?reset\b[^;&|]*--hard"#),
        (.cleanForce, #"\bgit\s+([^;&|]*\s)?clean\b[^;&|]*\s(-[a-z]*f[a-z]*|--force)(\s|$)"#),
        (.discardChanges, #"\bgit\s+([^;&|]*\s)?(checkout\s+(-f\s+)?(--\s+)?\.|restore\s+([^;&|]*\s)?\.|checkout\s+(-f|--force))(\s|$)"#),
        (.recursivePermissions, #"\b(chmod|chown|chgrp)\s+([^;&|]*\s)?(-[a-z]*r[a-z]*|--recursive)(\s|$)"#),
        (.sudo, #"(^|[;&|(]\s*|\s)sudo(\s|$)"#),
        (.pipeToShell, #"\b(curl|wget)\b[^;&]*\|\s*(sudo\s+)?(env\s+)?(ba|z|da|k|fi)?sh\b"#),
        (.diskWrite, #"(\bdd\b[^;&|]*\bof=|\bmkfs(\.\w+)?\b)"#),
        (.sqlDestructive, #"\b(drop\s+(table|database|schema|index)|truncate\s+(table\s+)?[\w"`])"#),
        (.forceKill, #"(\bkill\s+(-9|-kill|-s\s*kill)\b|\bpkill\b|\bkillall\b)"#),
        (
            .sensitiveWrite,
            #"(>>?|\btee\b|\bcp\b|\bmv\b|\bsed\s+-i|\bchmod\b)[^;&|]*(\.ssh/|\.aws/|\.netrc|\.npmrc|id_rsa|id_ed25519|credentials|\.env(\.local|\.production|\.development)?(\s|$|"|'))"#
        ),
    ]

    private static let sensitivePathPattern =
        #"(^|/)(\.ssh/|\.aws/|\.netrc$|\.npmrc$|id_rsa|id_ed25519|credentials(\.json)?$|\.env(\.local|\.production|\.development)?$)"#

    /// Every rule the tool call trips, most severe first; empty when none.
    static func matches(for tool: AttentionPendingTool) -> [AttentionRisk] {
        var found: [AttentionRisk] = []
        let command = tool.command.lowercased()
        if !command.isEmpty {
            for (risk, pattern) in shellRules where command.range(of: pattern, options: .regularExpression) != nil {
                found.append(risk)
            }
        }
        if let path = tool.filePath?.lowercased(),
           path.range(of: sensitivePathPattern, options: .regularExpression) != nil,
           !found.contains(.sensitiveWrite) {
            found.append(.sensitiveWrite)
        }
        return found
    }

    /// The most severe match, or `nil` for anything the table does not know.
    static func first(for tool: AttentionPendingTool) -> AttentionRisk? {
        matches(for: tool).first
    }

    /// Localized one-line warning shown in the warning colour.
    var note: String {
        switch self {
        case .recursiveDelete:
            return String(localized: "attention.risk.recursiveDelete", defaultValue: "Deletes files recursively")
        case .forcePush:
            return String(localized: "attention.risk.forcePush", defaultValue: "Force-pushes and can overwrite remote history")
        case .resetHard:
            return String(localized: "attention.risk.resetHard", defaultValue: "Hard reset discards local changes")
        case .cleanForce:
            return String(localized: "attention.risk.cleanForce", defaultValue: "Removes untracked files permanently")
        case .discardChanges:
            return String(localized: "attention.risk.discardChanges", defaultValue: "Discards working-tree changes")
        case .recursivePermissions:
            return String(localized: "attention.risk.recursivePermissions", defaultValue: "Changes permissions or owner recursively")
        case .sudo:
            return String(localized: "attention.risk.sudo", defaultValue: "Runs with administrator rights")
        case .pipeToShell:
            return String(localized: "attention.risk.pipeToShell", defaultValue: "Runs a downloaded script")
        case .diskWrite:
            return String(localized: "attention.risk.diskWrite", defaultValue: "Writes to a disk or formats it")
        case .sqlDestructive:
            return String(localized: "attention.risk.sqlDestructive", defaultValue: "Drops or truncates database data")
        case .forceKill:
            return String(localized: "attention.risk.forceKill", defaultValue: "Force-kills processes")
        case .sensitiveWrite:
            return String(localized: "attention.risk.sensitiveWrite", defaultValue: "Writes to SSH keys, .env or credentials")
        }
    }
}
