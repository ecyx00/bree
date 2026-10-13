import BreeBrowser
import Foundation
import Testing

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

@MainActor
@Suite(.serialized)
struct BrowserMediaPlaybackAudioActivityTests {
    @Test func activeSilentMediaPlaybackBlocksDiscardWithoutAudioGlyph() {
        let panel = BrowserPanel(workspaceId: UUID(), renderInitialNavigation: false)
        defer { panel.close() }

        panel.applyMediaPlaybackReport(
            BrowserMediaPlaybackReport(frameID: "main", isPlaying: true, isAudible: false)
        )

        #expect(panel.isPlayingMedia)
        #expect(panel.isPlayingAudio == false)
    }

    @Test func audibleMediaPlaybackDrivesAudioGlyphIndependentlyOfDiscardBlocker() {
        let panel = BrowserPanel(workspaceId: UUID(), renderInitialNavigation: false)
        defer { panel.close() }

        panel.applyMediaPlaybackReport(
            BrowserMediaPlaybackReport(frameID: "main", isPlaying: true, isAudible: true)
        )

        #expect(panel.isPlayingMedia)
        #expect(panel.isPlayingAudio)

        panel.applyMediaPlaybackReport(
            BrowserMediaPlaybackReport(frameID: "main", isPlaying: true, isAudible: false)
        )

        #expect(panel.isPlayingMedia)
        #expect(panel.isPlayingAudio == false)
    }
}
