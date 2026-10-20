public import Foundation
public import GhosttyKit
public import BreeAppSupport

// MARK: - Render grid export

extension TerminalSurface {
    /// Exports the surface grid as a remote render frame (optionally filtered
    /// to changed rows). Set `includeTheme` to `false` for ordinary live ticks
    /// after the caller has cached this surface's theme; replay and invalidation
    /// snapshots should retain the default complete theme payload. A `.screen`
    /// anchor exports the active area (independent of this surface's scroll
    /// position) for consumers that keep their own local viewport/scrollback.
    @MainActor
    public func renderGridFrame(
        stateSeq: UInt64,
        renderEpoch: String = "",
        renderRevision: UInt64 = 0,
        full: Bool = true,
        changedRows: Set<Int>? = nil,
        scrollbackLines: Int = 0,
        includeTheme: Bool = true,
        anchor: TerminalRenderGridFrame.Anchor = .viewport
    ) -> (frame: TerminalRenderGridFrame, rows: [String])? {
        guard let surface = liveSurfaceForGhosttyAccess(reason: "renderGrid") else { return nil }
        let surfaceID = id.uuidString
        let exported = surfaceID.withCString { ptr in
            ghostty_surface_render_grid_json_v2(
                surface,
                ptr,
                UInt(surfaceID.utf8.count),
                stateSeq,
                UInt(max(0, scrollbackLines)),
                includeTheme,
                anchor == .screen
            )
        }
        defer { ghostty_string_free(exported) }
        guard let ptr = exported.ptr, exported.len > 0 else { return nil }

        let data = Data(bytes: ptr, count: Int(exported.len))
        guard var fullFrame = try? JSONDecoder().decode(TerminalRenderGridFrame.self, from: data) else {
            return nil
        }
        fullFrame.renderEpoch = renderEpoch
        fullFrame.renderRevision = renderRevision
        if fullFrame.modes.contains(where: { !$0.ansi && $0.code == 5 && $0.on }) {
            // Ghostty exports renderer-effective defaults. Keep the v1 outer
            // fields raw because older iOS clients replay DEC reverse separately.
            let foreground = fullFrame.terminalForeground
            fullFrame.terminalForeground = fullFrame.terminalBackground
            fullFrame.terminalBackground = foreground
        }
        let frame: TerminalRenderGridFrame
        if full, changedRows == nil {
            frame = fullFrame
        } else {
            let includedRows = changedRows ?? Set(0..<fullFrame.rows)
            guard let filtered = try? fullFrame.filteredRows(includedRows, full: full) else {
                return nil
            }
            frame = filtered
        }
        return (frame, frame.plainRows())
    }
}
