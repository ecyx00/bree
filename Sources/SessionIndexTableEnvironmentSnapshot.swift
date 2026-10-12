import CmuxFoundation
import SwiftUI

/// Value-only SwiftUI environment forwarded into each independently hosted Vault row.
struct SessionIndexTableEnvironmentSnapshot {
    static let fallback = SessionIndexTableEnvironmentSnapshot(
        colorScheme: .light,
        globalFontMagnificationPercent: GlobalFontMagnification.defaultPercent
    )

    let colorScheme: ColorScheme
    let globalFontMagnificationPercent: Int
    /// Interface text size (`app.interfaceTextSize`); row heights follow the Bree type roles.
    var interfaceTextSize: Int = InterfaceTextSize.stored

    func hasEquivalentPresentation(to other: Self) -> Bool {
        colorScheme == other.colorScheme
            && globalFontMagnificationPercent == other.globalFontMagnificationPercent
            && interfaceTextSize == other.interfaceTextSize
    }

    @ViewBuilder
    func apply<Content: View>(to content: Content) -> some View {
        content
            .environment(\.colorScheme, colorScheme)
            .environment(\.cmuxGlobalFontMagnificationPercent, globalFontMagnificationPercent)
            .environment(\.breeInterfaceTextSize, interfaceTextSize)
            .breePaletteEnvironment()
    }
}
