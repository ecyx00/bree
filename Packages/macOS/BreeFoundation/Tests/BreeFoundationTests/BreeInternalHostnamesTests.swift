import Foundation
import Testing
@testable import BreeFoundation

/// Covers ``BreeInternalHostnames``: the slug algorithm shared by the app
/// (building a link) and the CLI (writing `/etc/hosts`), and the managed-block
/// splice that must never disturb the user's own entries.
@Suite("Internal hostnames")
struct BreeInternalHostnamesTests {
    @Test("Prefers a slugged label over the id; falls back when the label has nothing usable")
    func hostnamePrefersLabel() {
        #expect(BreeInternalHostnames().hostname(id: "vm-abc123", label: "My Server!") == "my-server.internal")
        #expect(BreeInternalHostnames().hostname(id: "vm-abc123", label: nil) == "vm-abc123.internal")
        #expect(BreeInternalHostnames().hostname(id: "vm-abc123", label: "🎉🎉🎉") == "vm-abc123.internal")
    }

    @Test("Slugging lowercases, collapses runs of separators, and trims edges")
    func slugNormalizes() {
        #expect(BreeInternalHostnames().slug("My  Cool_Server!!") == "my-cool-server")
        #expect(BreeInternalHostnames().slug("  --leading and trailing--  ") == "leading-and-trailing")
        #expect(BreeInternalHostnames().slug("") == nil)
        #expect(BreeInternalHostnames().slug("!!!") == nil)
    }

    @Test("Renders one sorted line per hostname, across machines")
    func rendersSortedBody() {
        let entries = [
            BreeInternalHostnames.Entry(address: "10.0.0.2", hostnames: ["vm-b.internal", "staging.internal"]),
            BreeInternalHostnames.Entry(address: "10.0.0.1", hostnames: ["vm-a.internal"]),
        ]
        #expect(BreeInternalHostnames().renderBlockBody(entries) == [
            "10.0.0.1 vm-a.internal",
            "10.0.0.2 staging.internal",
            "10.0.0.2 vm-b.internal",
        ].joined(separator: "\n"))
    }

    @Test("Appends the managed block to a file with no prior block")
    func appendsWhenAbsent() {
        let current = "127.0.0.1 localhost\n"
        let merged = BreeInternalHostnames().mergedHostsFile(current: current, body: "10.0.0.1 vm-a.internal")
        #expect(merged.contains("127.0.0.1 localhost"))
        #expect(merged.contains(BreeInternalHostnames().blockBeginMarker))
        #expect(merged.contains("10.0.0.1 vm-a.internal"))
        #expect(merged.contains(BreeInternalHostnames().blockEndMarker))
    }

    @Test("Replaces a prior block in place, leaving surrounding lines untouched")
    func replacesExistingBlock() {
        let current = """
        127.0.0.1 localhost
        \(BreeInternalHostnames().blockBeginMarker)
        10.0.0.1 vm-old.internal
        \(BreeInternalHostnames().blockEndMarker)
        192.168.1.1 nas.local
        """
        let merged = BreeInternalHostnames().mergedHostsFile(current: current, body: "10.0.0.2 vm-new.internal")
        #expect(!merged.contains("vm-old.internal"))
        #expect(merged.contains("vm-new.internal"))
        #expect(merged.contains("192.168.1.1 nas.local"))
        #expect(merged.contains("127.0.0.1 localhost"))
    }

    @Test("An empty body removes the block entirely, without leaving a stray blank line")
    func emptyBodyRemovesBlock() {
        let current = """
        127.0.0.1 localhost

        \(BreeInternalHostnames().blockBeginMarker)
        10.0.0.1 vm-old.internal
        \(BreeInternalHostnames().blockEndMarker)
        """
        let merged = BreeInternalHostnames().mergedHostsFile(current: current, body: "")
        #expect(!merged.contains("bree managed"))
        #expect(!merged.contains("vm-old.internal"))
        #expect(merged == "127.0.0.1 localhost")
    }

    @Test("An already-empty file with an empty body changes nothing")
    func emptyBodyOnFileWithNoBlockIsANoOp() {
        let current = "127.0.0.1 localhost\n"
        #expect(BreeInternalHostnames().mergedHostsFile(current: current, body: "") == current)
    }

    @Test("A port link is always the raw private address, never the .internal name")
    func directPortURLUsesTheRawAddress() {
        // Deliberately not the `.internal` name: it only resolves once
        // `bree vpn hosts` has synced `/etc/hosts`, and a link that only
        // sometimes works is worse than one that always does.
        #expect(BreeInternalHostnames().directPortURL(privateAddress: "10.0.0.2", port: 8000) == "http://10.0.0.2:8000")
    }

    @Test("Brackets an IPv6 address the way every URL scheme requires")
    func directPortURLBracketsIPv6() {
        #expect(
            BreeInternalHostnames().directPortURL(privateAddress: "fd60:1e5e:6720::3", port: 22)
                == "http://[fd60:1e5e:6720::3]:22"
        )
    }

    @Test("A dev build's scoped block coexists with the production block; each clears only its own")
    func scopedBlocksCoexist() {
        let prod = BreeInternalHostnames().mergedHostsFile(current: "127.0.0.1 localhost\n", body: "10.16.179.2 prod.internal")
        let both = BreeInternalHostnames().mergedHostsFile(current: prod, body: "10.16.170.2 dev.internal", scope: "bree-staging")
        #expect(both.contains("10.16.179.2 prod.internal"))
        #expect(both.contains("10.16.170.2 dev.internal"))
        #expect(both.contains("# BEGIN bree managed hosts [bree-staging] (bree vpn hosts)"))
        #expect(both.contains(BreeInternalHostnames().blockBeginMarker), "the production block keeps its historical markers")
        // The default scope name is the unscoped block.
        #expect(BreeInternalHostnames().blockBeginMarker(scope: "bree") == BreeInternalHostnames().blockBeginMarker)
        #expect(BreeInternalHostnames().blockBeginMarker(scope: nil) == BreeInternalHostnames().blockBeginMarker)
        let devCleared = BreeInternalHostnames().mergedHostsFile(current: both, body: "", scope: "bree-staging")
        #expect(devCleared.contains("prod.internal") && !devCleared.contains("dev.internal"))
        let prodCleared = BreeInternalHostnames().mergedHostsFile(current: both, body: "", scope: "bree")
        #expect(!prodCleared.contains("prod.internal") && prodCleared.contains("dev.internal"))
    }
}
