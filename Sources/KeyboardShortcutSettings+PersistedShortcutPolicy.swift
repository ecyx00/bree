import BreeSettings

/// Bridges the app target's legacy shortcut representation into the shared
/// action-owned persistence policy.
extension KeyboardShortcutSettings.Action {
    func shortcutBindingPolicyRejection(
        for shortcut: StoredShortcut
    ) -> KeyboardShortcutSettings.ShortcutRecordingRejection? {
        guard let settingsAction = BreeSettings.ShortcutAction(rawValue: rawValue) else {
            return nil
        }

        switch settingsAction.shortcutBindingPolicyResult(
            for: shortcut.breeSettingsStoredShortcut
        ) {
        case .accepted:
            return nil
        case .primaryModifierRequired:
            return .systemWideHotkeyRequiresModifier
        case .bareFirstStrokeNotAllowed:
            return self == .showHideAllWindows
                ? .systemWideHotkeyRequiresModifier
                : .bareKeyNotAllowed
        case .chordNotAllowed,
             .systemDefinedMediaKeyNotAllowed,
             .systemReservedShortcutNotAllowed:
            return .reservedBySystem
        }
    }
}

extension KeyboardShortcutSettings {
    /// Resolves one persistence layer's candidate, falling back to a valid
    /// built-in default when the candidate cannot execute.
    static func effectivePersistedShortcut(
        _ candidate: StoredShortcut?,
        for action: Action,
        managedBySettingsFile: Bool = false
    ) -> StoredShortcut? {
        if managedBySettingsFile,
           candidate == nil,
           action == .showHideAllWindows {
            return nil
        }

        guard let settingsAction = BreeSettings.ShortcutAction(rawValue: action.rawValue) else {
            return nil
        }

        return settingsAction.effectivePersistedShortcut(
            candidate?.breeSettingsStoredShortcut,
            defaultShortcut: action.defaultShortcut.breeSettingsStoredShortcut,
            normalizing: { shortcut in
                normalizedExecutableShortcut(
                    StoredShortcut(breeSettingsStoredShortcut: shortcut),
                    for: action
                )?.breeSettingsStoredShortcut
            },
            conflictsWithReservedShortcut: { shortcut in
                conflictsWithConfiguredSystemWideHotkey(
                    StoredShortcut(breeSettingsStoredShortcut: shortcut),
                    action: action
                )
            }
        ).map(StoredShortcut.init(breeSettingsStoredShortcut:))
    }

    private static func normalizedExecutableShortcut(
        _ shortcut: StoredShortcut,
        for action: Action
    ) -> StoredShortcut? {
        guard case let .accepted(normalized) = action
            .resolvedRecordedShortcutIgnoringConflicts(
                shortcut,
                checkingSystemWideConflicts: false
            ) else {
            return nil
        }
        return normalized
    }

    private static func conflictsWithConfiguredSystemWideHotkey(
        _ shortcut: StoredShortcut,
        action: Action
    ) -> Bool {
        guard action == .globalSearch,
              let proposedPrefix = shortcut.firstStroke.carbonHotKeyRegistration,
              let systemWideHotkey = SystemWideHotkeySettings.registrationCandidate(
                for: SystemWideHotkeySettings.shortcut()
              )?.registration else {
            return false
        }
        return proposedPrefix == systemWideHotkey
    }
}

extension SystemWideHotkeySettings {
    /// Resolves a complete Show/Hide binding into the Carbon registration shape
    /// shared by conflict arbitration and the actual system-wide registrar.
    ///
    /// Global Search intentionally yields to this candidate. Every other
    /// application and AppKit reservation is validated before it can reserve
    /// the foreground shortcut or reach the registrar.
    static func registrationCandidate(
        for shortcut: StoredShortcut
    ) -> (shortcut: StoredShortcut, registration: CarbonHotKeyRegistration)? {
        guard case let .accepted(normalizedShortcut) = action
            .resolvedRecordedShortcutIgnoringConflicts(
                shortcut,
                checkingSystemWideConflicts: false
            ),
            let registration = normalizedShortcut.carbonHotKeyRegistration,
            !KeyboardShortcutSettings.systemWideHotkeyConflicts(
                with: normalizedShortcut,
                excluding: action,
                alsoExcluding: [.globalSearch]
            ) else {
            return nil
        }
        return (normalizedShortcut, registration)
    }
}

extension StoredShortcut {
    init(breeSettingsStoredShortcut shortcut: BreeSettings.StoredShortcut) {
        self.init(
            first: ShortcutStroke(breeSettingsShortcutStroke: shortcut.first),
            second: shortcut.second.map(ShortcutStroke.init(breeSettingsShortcutStroke:))
        )
    }

    var breeSettingsStoredShortcut: BreeSettings.StoredShortcut {
        BreeSettings.StoredShortcut(
            first: firstStroke.breeSettingsShortcutStroke,
            second: secondStroke?.breeSettingsShortcutStroke
        )
    }
}

extension ShortcutStroke {
    init(breeSettingsShortcutStroke stroke: BreeSettings.ShortcutStroke) {
        self.init(
            key: stroke.key,
            command: stroke.command,
            shift: stroke.shift,
            option: stroke.option,
            control: stroke.control,
            keyCode: stroke.keyCode
        )
    }

    var breeSettingsShortcutStroke: BreeSettings.ShortcutStroke {
        BreeSettings.ShortcutStroke(
            key: key,
            command: command,
            shift: shift,
            option: option,
            control: control,
            keyCode: keyCode
        )
    }
}
