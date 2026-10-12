/// The mutually exclusive live, frozen, or teardown payload for an orphan route.
@MainActor
enum RecoverableMainWindowRoutePayload {
    case live(
        sidebar: SidebarState,
        sidebarSelection: SidebarSelectionState
    )
    case frozen(SessionWindowSnapshot)
    case teardown
}
