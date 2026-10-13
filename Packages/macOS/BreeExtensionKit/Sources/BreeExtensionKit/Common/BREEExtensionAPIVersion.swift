import Foundation

public struct BreeExtensionAPIVersion: Codable, Comparable, Equatable, Sendable {
    public var major: Int
    public var minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    public static let sidebarV2 = BreeExtensionAPIVersion(major: 2, minor: 0)

    public static func < (lhs: BreeExtensionAPIVersion, rhs: BreeExtensionAPIVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        return lhs.minor < rhs.minor
    }
}
