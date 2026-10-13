import BreeFoundation

/// One configuration transaction's font-scale boundary.
///
/// Settings reload before the target is sampled, so a value imported from
/// bree.json and the Ghostty config built in this transaction cannot diverge.
@MainActor
struct TerminalFontConfigurationReloadTransaction {
    let previousMagnificationPercent: Int
    let targetMagnificationPercent: Int

    var magnificationDidChange: Bool {
        previousMagnificationPercent
            != targetMagnificationPercent
    }

    static func prepare(
        appliedMagnificationPercent: Int,
        reloadSettings: @MainActor () -> Void,
        storedMagnificationPercent: @MainActor () -> Int
    ) -> Self {
        let previousMagnificationPercent =
            GlobalFontMagnification.clamp(
                appliedMagnificationPercent
            )
        reloadSettings()
        return Self(
            previousMagnificationPercent:
                previousMagnificationPercent,
            targetMagnificationPercent:
                GlobalFontMagnification.clamp(
                    storedMagnificationPercent()
                )
        )
    }
}
