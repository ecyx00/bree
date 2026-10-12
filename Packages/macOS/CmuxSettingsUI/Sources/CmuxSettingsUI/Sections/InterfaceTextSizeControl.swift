import CmuxFoundation
import SwiftUI

struct InterfaceTextSizeControl: View {
    let size: Int
    let onChange: (Int) -> Void

    private var clampedSize: Int {
        InterfaceTextSize.clamp(size)
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(String(format: "%d pt", clampedSize))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .frame(minWidth: 48, alignment: .trailing)

            Stepper(
                "",
                value: Binding(
                    get: { clampedSize },
                    set: { onChange(InterfaceTextSize.clamp($0)) }
                ),
                in: InterfaceTextSize.minimumSize...InterfaceTextSize.maximumSize,
                step: InterfaceTextSize.step
            )
            .labelsHidden()
            .accessibilityLabel(String(localized: "settings.app.interfaceTextSize", defaultValue: "Interface Text Size"))
            .accessibilityValue(Text("\(clampedSize) pt"))
            .accessibilityIdentifier("SettingsInterfaceTextSizeStepper")

            Button(String(localized: "settings.app.globalFontMagnification.reset", defaultValue: "Reset")) {
                onChange(InterfaceTextSize.defaultSize)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(clampedSize == InterfaceTextSize.defaultSize)
        }
        .cmuxFont(.body)
    }
}
