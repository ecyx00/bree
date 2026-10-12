import Foundation
import Testing
@testable import cmux_DEV

@Suite("AgentImageDiscovery")
struct AgentImageStripTests {
    @Test func sortsNumericallyAndFiltersExtensions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-img-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("proj/sess-1/images")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["10.png", "2.png", "1.JPG", "3.txt", "4.webp", "notes.png", "5.gif", "6.jpeg"] {
            try Data([0]).write(to: dir.appendingPathComponent(name))
        }
        let found = AgentImageDiscovery.discover(root: root, sessionID: "sess-1")
        #expect(found.map { $0.url.lastPathComponent } == ["1.JPG", "2.png", "4.webp", "5.gif", "6.jpeg", "10.png", "notes.png"])
        #expect(found.first?.title == "Image #1")
        #expect(AgentImageDiscovery.discover(root: root, sessionID: "other").isEmpty)
    }
}
