import Foundation

/// One edit to the settings in the global bree.json.
///
/// Both `"type": "setting"` / `"type": "settingPreset"` actions and
/// `bree config set|unset|toggle|cycle|preset` describe their edit with this
/// type and apply it through ``JSONConfigStore/apply(_:)``, so every
/// entrypoint validates and writes the same way.
public enum BreeSettingChange: Sendable, Hashable {
    /// Writes `value` at the dotted settings `path`.
    case set(path: String, value: BreeSettingValue)
    /// Removes `path`, so bree falls back to the default.
    case unset(path: String)
    /// Flips a boolean setting. An absent key flips its schema default.
    case toggle(path: String)
    /// Advances `path` to the entry after its current value in `values`,
    /// wrapping at the end. A value that isn't in the list, including an
    /// absent key whose default isn't listed, moves to the first entry.
    case cycle(path: String, values: [BreeSettingValue])
    /// Merges the partial settings object stored at `settingPresets.<name>`
    /// in the same file. Nested objects merge key by key; every other value,
    /// including arrays, replaces the current one.
    case preset(name: String)

    /// The settings path this change edits, or the preset name.
    public var displayTarget: String {
        switch self {
        case .set(let path, _), .unset(let path), .toggle(let path), .cycle(let path, _):
            return path
        case .preset(let name):
            return name
        }
    }

    /// The equivalent `bree config` command, shown when a setting action
    /// asks for confirmation.
    public var commandLineDescription: String {
        switch self {
        case .set(let path, let value):
            return "bree config set \(path) \(value.jsonText)"
        case .unset(let path):
            return "bree config unset \(path)"
        case .toggle(let path):
            return "bree config toggle \(path)"
        case .cycle(let path, let values):
            return (["bree config cycle", path] + values.map(\.jsonText)).joined(separator: " ")
        case .preset(let name):
            return "bree config preset \(name)"
        }
    }
}

/// The paths a ``BreeSettingChange`` wrote. Runtime application is not
/// observed: bree's config file watcher applies the saved file.
public struct BreeSettingChangeResult: Sendable {
    /// One receipt per path the change addressed, in the order the change
    /// produced them. A path that already held the requested value has
    /// equal `before` and `installed` data.
    public let receipts: [JSONConfigMutationReceipt]

    /// The value now stored at `path`, or nil when this change removed it or
    /// didn't touch it.
    public func installedValue(at path: String) -> BreeSettingValue? {
        guard let data = receipts.last(where: { $0.path == path })?.installed,
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return BreeSettingValue(jsonObject: object)
    }
}
