import BreeTerminalCore

/// Lets `BreeConfigStoreReloadCoordinator` drive per-window config reloads through a
/// protocol seam. `BreeConfigStore`'s existing `loadAll()` already satisfies the
/// requirement, so this conformance is empty.
extension BreeConfigStore: BreeConfigStoreReloading {}
