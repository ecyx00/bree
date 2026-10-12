import CmuxFoundation
import SwiftUI

/// SwiftUI bridge for the AppKit-virtualized Vault session list.
struct SessionIndexTableView: NSViewRepresentable {
    let rows: [SessionIndexTableRow]
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var globalFontMagnificationPercent
    @Environment(\.breeInterfaceTextSize) private var interfaceTextSize

    func makeCoordinator() -> SessionIndexTableController {
        SessionIndexTableController()
    }

    func makeNSView(context: Context) -> SessionIndexTableContainerView {
        context.coordinator.makeContainerView()
    }

    func updateNSView(_ nsView: SessionIndexTableContainerView, context: Context) {
        context.coordinator.apply(
            rows: rows,
            environment: SessionIndexTableEnvironmentSnapshot(
                colorScheme: colorScheme,
                globalFontMagnificationPercent: globalFontMagnificationPercent,
                interfaceTextSize: interfaceTextSize
            )
        )
    }

    static func dismantleNSView(
        _ nsView: SessionIndexTableContainerView,
        coordinator: SessionIndexTableController
    ) {
        coordinator.dismantle()
    }
}
