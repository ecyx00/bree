import Foundation
import BreeFoundation
import BreeTerminalCore

// BreeSurfaceConfigTemplate and the surface runtime probes moved to
// BreeTerminalCore (SurfaceValues/BreeSurfaceConfigTemplate.swift and
// Interop/GhosttySurfaceRuntimeProbe.swift). The legacy free-function names
// below are shims forwarding existing app callers to the probe.

typealias BreeSurfaceConfigTemplate = BreeTerminalCore.BreeSurfaceConfigTemplate

func breeSurfaceContextName(_ context: ghostty_surface_context_e) -> String {
    GhosttySurfaceRuntimeProbe.contextName(context)
}

func breeSurfacePointerAppearsLive(_ surface: ghostty_surface_t) -> Bool {
    GhosttySurfaceRuntimeProbe.surfacePointerAppearsLive(surface)
}

@MainActor
func breeCurrentSurfaceFontSizePoints(_ surface: ghostty_surface_t) -> Float? {
    GhosttySurfaceRuntimeProbe.currentSurfaceFontSizePoints(surface)
}

@MainActor
func breeInheritedSurfaceConfig(
    sourceSurface: ghostty_surface_t,
    context: ghostty_surface_context_e
) -> BreeSurfaceConfigTemplate {
    let inherited = ghostty_surface_inherited_config(sourceSurface, context)
    let percent = GlobalFontMagnification.storedPercent
    var config = BreeSurfaceConfigTemplate(
        cConfig: inherited,
        globalFontMagnificationPercent: percent
    )

    // Capture runtime zoom for inheritance, even when Ghostty's inherit-font-size
    // config is disabled, without claiming surface-local ownership.
    let runtimePoints = breeCurrentSurfaceFontSizePoints(sourceSurface)
    if let points = runtimePoints {
        config.setFontSize(
            BreeSurfaceConfigTemplate.baseFontSize(
                fromRuntimePoints: points,
                percent: percent
            ),
            isExplicitOverride: false
        )
    }

#if DEBUG
    let inheritedText = String(format: "%.2f", inherited.font_size)
    let runtimeText = runtimePoints.map { String(format: "%.2f", $0) } ?? "nil"
    let finalText = String(format: "%.2f", config.fontSize)
    breeDebugLog(
        "zoom.inherit context=\(breeSurfaceContextName(context)) " +
        "inherited=\(inheritedText) runtime=\(runtimeText) final=\(finalText)"
    )
#endif

    return config
}
