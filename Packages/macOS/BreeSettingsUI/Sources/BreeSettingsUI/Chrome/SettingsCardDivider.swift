import AppKit
import BreeFoundation
import SwiftUI

/// 1pt half-opacity separator drawn between two ``SettingsCardRow``s
/// inside a ``SettingsCard``.
@MainActor
public struct SettingsCardDivider: View {
    @Environment(\.breePalette) private var palette
    public init() {}

    public var body: some View {
        Rectangle()
            .fill(palette.separator)
            .frame(height: 1)
    }
}
