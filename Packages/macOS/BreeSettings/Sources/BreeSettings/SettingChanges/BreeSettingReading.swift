import Foundation

/// A settings path as `bree config get` reports it.
public struct BreeSettingReading: Sendable, Equatable {
    /// The dotted path that was read.
    public let path: String
    /// The value bree.json sets, or nil when the key is absent.
    public let configured: BreeSettingValue?
    /// The value stored outside bree.json, such as one set in the Settings
    /// window, or nil when there is none.
    public let live: BreeSettingValue?
    /// The schema default, or nil when the schema declares none.
    public let defaultValue: BreeSettingValue?

    /// The value bree uses: the configured value, else the live value, else
    /// the default.
    public var effective: BreeSettingValue? {
        configured ?? live ?? defaultValue
    }
}

extension JSONConfigStore {
    /// Reads one settings path straight from disk, validated the same way
    /// ``apply(_:)`` validates a write.
    ///
    /// - Parameter liveValues: Where to read the value of a key the file
    ///   doesn't set, as in ``apply(_:liveValues:)``.
    /// - Throws: ``BreeSettingChangeError`` for an unknown or non-setting
    ///   path, or a read/parse error for an unreadable file.
    public nonisolated func reading(
        at path: String,
        liveValues: BreeSettingLiveValues = .schemaDefaultsOnly
    ) throws -> BreeSettingReading {
        let planner = BreeSettingChangePlanner(liveValues: liveValues)
        let root = try snapshotRoot()
        let jsonPath = try planner.settingPath(path, root: root)
        let configured = jsonPath.lookup(in: root).flatMap(BreeSettingValue.init(jsonObject:))
        return BreeSettingReading(
            path: path,
            configured: configured,
            live: configured == nil ? planner.liveValue(at: jsonPath) : nil,
            defaultValue: planner.defaultValue(at: jsonPath).flatMap(BreeSettingValue.init(jsonObject:))
        )
    }
}
