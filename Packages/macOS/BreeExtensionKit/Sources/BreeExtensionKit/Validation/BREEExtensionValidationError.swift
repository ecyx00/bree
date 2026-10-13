import Foundation

@_spi(BreeHostTransport)
public enum BreeExtensionValidationError: Error, Equatable, Sendable {
    case unsupportedAPIVersion(requested: BreeExtensionAPIVersion, supported: BreeExtensionAPIVersion)
    case emptyIdentifier
    case emptyDisplayName
    case payloadTooLarge(kind: String, actualBytes: Int, maximumBytes: Int)
}
