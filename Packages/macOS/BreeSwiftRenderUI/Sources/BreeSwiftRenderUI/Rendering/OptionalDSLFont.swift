import BreeFoundation
import SwiftUI

struct OptionalDSLFont: ViewModifier {
    let spec: DSLFontSpec?

    func body(content: Content) -> some View {
        if let spec {
            content.scaledFont(
                size: spec.baseSize,
                weight: spec.weight ?? .regular,
                design: spec.design
            )
        } else {
            content
        }
    }
}
