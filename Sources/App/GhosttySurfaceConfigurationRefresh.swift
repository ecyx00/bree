@MainActor
enum GhosttySurfaceConfigurationRefresh {
    nonisolated static let forceRefreshReason = "appDelegate.refreshAfterGhosttyConfigReload"
    nonisolated static let breeThemeReloadLegacySource = "distributed.bree.themes"
    nonisolated static let breeThemeReloadPreviewSource = "distributed.bree.themes.preview"
    nonisolated static let breeThemeReloadFinalSource = "distributed.bree.themes.final"
    nonisolated static let breeThemePreviewReloadDebounceMilliseconds = 180

    nonisolated static func breeThemeReloadSource(phase: String?) -> String {
        switch phase {
        case "final", "apply":
            return breeThemeReloadFinalSource
        case "preview":
            return breeThemeReloadPreviewSource
        default:
            return breeThemeReloadLegacySource
        }
    }

    nonisolated static func shouldDebounceBreeThemeReload(source: String) -> Bool {
        switch source {
        case breeThemeReloadLegacySource, breeThemeReloadPreviewSource:
            return true
        default:
            return false
        }
    }

    nonisolated static func isBreeThemeReloadSource(_ source: String) -> Bool {
        switch source {
        case breeThemeReloadLegacySource, breeThemeReloadPreviewSource, breeThemeReloadFinalSource:
            return true
        default:
            return false
        }
    }

    static func applyAfterAppConfigReload(
        to surface: ghostty_surface_t?,
        source: String,
        reloadSurfaceConfiguration: (ghostty_surface_t, Bool, String) -> Void,
        applySurfaceColorScheme: () -> Void,
        refreshHostBackground: () -> Void,
        forceRefresh: (String) -> Void
    ) {
        applyConfigurationReload(
            to: surface,
            soft: true,
            source: source,
            redrawReason: forceRefreshReason,
            reloadSurfaceConfiguration: reloadSurfaceConfiguration,
            applySurfaceColorScheme: applySurfaceColorScheme,
            refreshHostBackground: refreshHostBackground,
            forceRefresh: forceRefresh
        )
    }

    static func applyConfigurationReload(
        to surface: ghostty_surface_t?,
        soft: Bool,
        source: String,
        redrawReason: String,
        reloadSurfaceConfiguration: (ghostty_surface_t, Bool, String) -> Void,
        applySurfaceColorScheme: () -> Void,
        refreshHostBackground: () -> Void,
        forceRefresh: (String) -> Void
    ) {
        if let surface {
            reloadSurfaceConfiguration(surface, soft, source)
            // The scheme must resolve against the newly installed config. Applying
            // it to the stale config can emit an old background before the reload,
            // pairing that background with the new foreground (issues #8938, #9588).
            applySurfaceColorScheme()
        }
        refreshHostBackground()
        forceRefresh(redrawReason)
    }
}
