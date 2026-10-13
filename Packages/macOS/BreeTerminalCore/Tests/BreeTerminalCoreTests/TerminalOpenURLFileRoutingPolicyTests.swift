import Foundation
import Testing
import BreeTerminalCore

@Suite struct TerminalOpenURLFileRoutingPolicyTests {
    private let policy = TerminalOpenURLFileRoutingPolicy()

    @Test func explicitFileSchemeBypassesBreeFileRouting() throws {
        let url = try #require(URL(string: "file:///Users/dev/out/ab_cosyvoice_emo.wav"))
        #expect(
            policy.shouldAttemptBreeFileRouting(
                rawOpenURLValue: url.absoluteString,
                target: .external(url)
            ) == false
        )
    }

    @Test func localhostFileSchemeBypassesBreeFileRouting() throws {
        let url = try #require(URL(string: "file://localhost/Users/dev/out/ab_cosyvoice_emo.wav"))
        #expect(
            policy.shouldAttemptBreeFileRouting(
                rawOpenURLValue: url.absoluteString,
                target: .external(url)
            ) == false
        )
    }

    @Test func hostedFileTargetBypassesBreeFileRoutingEvenWithoutRawScheme() throws {
        let url = try #require(URL(string: "file://remote-host/Users/dev/out/ab_cosyvoice_emo.wav"))
        #expect(
            policy.shouldAttemptBreeFileRouting(
                rawOpenURLValue: "/Users/dev/out/ab_cosyvoice_emo.wav",
                target: .external(url)
            ) == false
        )
    }

    @Test func absolutePathCanStillUseBreeFileRouting() {
        let url = URL(fileURLWithPath: "/Users/dev/project/README.md")
        #expect(
            policy.shouldAttemptBreeFileRouting(
                rawOpenURLValue: "/Users/dev/project/README.md",
                target: .external(url)
            )
        )
    }

    @Test func nonFileTargetsBypassBreeFileRouting() throws {
        let url = try #require(URL(string: "https://example.com/audio.wav"))
        #expect(
            policy.shouldAttemptBreeFileRouting(
                rawOpenURLValue: url.absoluteString,
                target: .embeddedBrowser(url)
            ) == false
        )
    }
}
