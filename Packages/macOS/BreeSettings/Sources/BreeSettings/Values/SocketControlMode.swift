import Foundation

/// Controls which clients may connect to the bree automation socket.
///
/// Stored under the catalog entry ``SettingCatalog/automationSocketControlMode``.
/// The cases mirror the on-disk strings used by `~/.config/bree/bree.json` and
/// the legacy UserDefaults value, so the raw values must not be renamed without
/// a migration.
public enum SocketControlMode: String, CaseIterable, Sendable, SettingCodable {
    /// The automation socket is not exposed.
    case off
    /// Only the bundled `bree` CLI may connect.
    case breeOnly
    /// Automation tools (e.g. hooks for Claude, Cursor, Gemini) may connect.
    case automation
    /// Clients must present a password configured under
    /// ``SettingCatalog/automationSocketPassword``.
    case password
    /// Any local client may connect. Treat as developer-only.
    case allowAll
}
