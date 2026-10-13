public import SwiftUI

/// Injects the stored bree font magnification percent into a SwiftUI subtree.
struct BreeFontMagnificationEnvironmentModifier: ViewModifier {
    @AppStorage(GlobalFontMagnification.percentKey) private var percent = GlobalFontMagnification.defaultPercent

    @AppStorage(InterfaceTextSize.key) private var interfaceTextSize = InterfaceTextSize.defaultSize

    func body(content: Content) -> some View {
        content
            .environment(\.breeGlobalFontMagnificationPercent, percent)
            .environment(\.breeInterfaceTextSize, interfaceTextSize)
            // Every Bree window root applies this modifier, so it also carries the
            // chrome palette (`@Environment(\.breePalette)`).
            .breePaletteEnvironment()
    }
}
