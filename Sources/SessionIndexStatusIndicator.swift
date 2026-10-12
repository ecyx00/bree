import CmuxFoundation
import SwiftUI

/// Shared 6×6 status circle used by full Vault rows and their popovers.
/// Active sessions are green; inactive history is gray in every grouping.
struct SessionStatusIndicator: View {
    let model: SessionIndexStatusIndicatorModel
    @Environment(\.breePalette) private var palette

    init(isInPane: Bool, liveStatus: VaultSessionLiveStatus?) {
        model = .make(isInPane: isInPane, liveStatus: liveStatus)
    }

    var body: some View {
        ZStack {
            if model.isFilled {
                Circle().fill(model.color(palette: palette))
            } else {
                Circle().strokeBorder(model.color(palette: palette), lineWidth: 1)
            }
        }
            .frame(width: 6, height: 6)
            .help(model.label)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(model.label))
    }
}
