import AppKit
import BreeAppKitSupportUI
import BreeFoundation
import SwiftUI

/// Renders a magnified system symbol through the AppKit-backed icon renderer.
struct SessionIndexResolvedSystemSymbolImage: View {
    @Environment(\.breeGlobalFontMagnificationPercent) private var globalFontPercent

    let systemName: String
    let pointSize: CGFloat
    let size: CGFloat
    let weight: NSFont.Weight
    let tintColor: NSColor
    let fallbackSource: BreeResolvedIconSource?

    var body: some View {
        let rasterSize = GlobalFontMagnification.scaledSize(pointSize, percent: globalFontPercent)
        BreeResolvedIconImage(request: BreeResolvedIconRequest(
            source: .systemSymbol(name: systemName, accessibilityDescription: nil),
            size: NSSize(width: rasterSize, height: rasterSize),
            tintColor: tintColor,
            symbolWeight: weight,
            fallbackSource: fallbackSource
        ))
        // Keep the magnified raster's own layout size, then center it in the
        // design-size slot. This mirrors `BreeSystemSymbolImage(magnified:)`
        // and prevents the AppKit image view from scaling the larger bitmap
        // back down to the unscaled slot.
        .frame(width: rasterSize, height: rasterSize)
        .frame(width: size, height: size)
    }
}
