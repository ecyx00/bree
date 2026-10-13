import AppKit
import BreeFoundation
import SwiftUI

struct AcknowledgmentsView: View {
    private let content = AboutLicenseContent(bundle: .main).load()

    var body: some View {
        ScrollView {
            Text(content)
                .scaledFont(.body, design: .monospaced)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
    }
}
