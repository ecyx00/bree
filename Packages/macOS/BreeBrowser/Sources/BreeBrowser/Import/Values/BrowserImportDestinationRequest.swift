public import Foundation

/// A request for the bree destination profile an import entry should write to.
public enum BrowserImportDestinationRequest: Equatable, Sendable {
    /// Import into the existing bree profile with this identifier.
    case existing(UUID)
    /// Create a new bree profile with this display name, then import into it.
    case createNamed(String)
}
