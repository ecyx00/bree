import Foundation
import Testing
import CmuxTerminalCore

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Quoted and escaped directory words resolve to the real directory, and the
/// insertion text keeps the unescaped path (the controller escapes it again).
struct TerminalCompletionPathTests {
    private func makeTree() throws -> String {
        let root = NSTemporaryDirectory() + "cmux-completion-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/Desktop/Muhasebe v2", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/My Dir", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/a b", withIntermediateDirectories: true)
        fm.createFile(atPath: root + "/Desktop/Muhasebe v2/inner.txt", contents: Data())
        fm.createFile(atPath: root + "/My Dir/in-my-dir.txt", contents: Data())
        fm.createFile(atPath: root + "/a b/in-a-b.txt", contents: Data())
        fm.createFile(atPath: root + "/Desktop/sibling.txt", contents: Data())
        return root
    }

    private func titles(_ buffer: String, cwd: String) -> [String] {
        let context = TerminalCompletionContext.parse(buffer: buffer, caret: buffer.count)
        return TerminalCompletionProviders.pathCandidates(
            word: context.word, cwd: cwd, directoriesOnly: false, isCancelled: { false }
        ).map(\.title)
    }

    @Test("Escaped space lists the directory, not its parent")
    func escapedSpace() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(titles("cd Desktop/Muhasebe\\ v2/", cwd: root) == ["inner.txt"])
    }

    @Test("Double-quoted and single-quoted directories")
    func quotes() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(titles("cd \"My Dir/\"", cwd: root) == ["in-my-dir.txt"])
        #expect(titles("cd 'a b'/", cwd: root) == ["in-a-b.txt"])
    }

    private func candidates(_ buffer: String, cwd: String) -> [TerminalCompletionCandidate] {
        let context = TerminalCompletionContext.parse(buffer: buffer, caret: buffer.count)
        return TerminalCompletionProviders.pathCandidates(
            word: context.word, cwd: cwd, directoriesOnly: false, isCancelled: { false }
        )
    }

    @Test("A token ending in slash lists the children")
    func trailingSlashListsChildren() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(titles("ls Desktop/", cwd: root) == ["Muhasebe v2/", "sibling.txt"])
    }

    @Test("Accepting a directory yields dir/ with no space, and the refetch is non-empty")
    func directoryAcceptThenRefetch() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let dir = try #require(candidates("ls Desk", cwd: root).first)
        #expect(dir.replacementText == "Desktop/")
        // The accepted text replaces the word; parse and list again.
        let buffer = "ls " + dir.replacementText
        #expect(!titles(buffer, cwd: root).isEmpty)
        let nested = try #require(candidates(buffer, cwd: root).first)
        #expect(nested.replacementText == "Desktop/Muhasebe\\ v2/")
        #expect(titles("ls " + nested.replacementText, cwd: root) == ["inner.txt"])
    }

    @Test("A single candidate completes inline, files end with a space")
    func singleCandidateInline() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let found = candidates("cat Desktop/sib", cwd: root)
        #expect(found.count == 1)
        #expect(found[0].replacementText == "Desktop/sibling.txt ")
        #expect(TerminalCompletionInline.ghostSuffix(rawWord: "Desktop/sib", candidate: found[0]) == "ling.txt")
    }

    @Test("Common prefix, ghost segment")
    func inlineHelpers() {
        func dir(_ s: String) -> TerminalCompletionCandidate { .init(kind: .directory, title: s, insertion: s) }
        #expect(TerminalCompletionInline.commonPrefixSuffix(rawWord: "Pro", candidates: [dir("Project-a/"), dir("Project-b/")]) == "ject-")
        #expect(TerminalCompletionInline.commonPrefixSuffix(rawWord: "Pro", candidates: [dir("Projects/"), dir("Programs/")]) == nil)
        #expect(TerminalCompletionInline.firstSegment(of: "ects/bree/") == "ects/")
        #expect(TerminalCompletionInline.firstSegment(of: " -la foo") == " -la ")
        #expect(TerminalCompletionInline.firstSegment(of: "My\\ Dir/x") == "My\\ Dir/")
    }

    @Test("cd with an empty word lists only directories of the cwd")
    func cdEmptyWordListsDirectories() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(atPath: root) }
        FileManager.default.createFile(atPath: root + "/plain.txt", contents: Data())
        let context = TerminalCompletionContext.parse(buffer: "cd ", caret: 3)
        #expect(!context.isCommandPosition)
        let found = TerminalCompletionProviders.pathCandidates(
            word: context.word, cwd: root, directoriesOnly: true, isCancelled: { false }
        )
        #expect(!found.isEmpty)
        #expect(found.allSatisfy { $0.kind == .directory })
    }

    @Test("A relative word resolves against the given cwd, not a stale one")
    func relativeWordUsesCwd() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(titles("cd Des", cwd: root) == ["Desktop/"])
        #expect(titles("cd Des", cwd: root + "/My Dir").isEmpty)
        let found = candidates("cd Des", cwd: root)
        #expect(TerminalCompletionInline.ghostSuffix(rawWord: "Des", candidate: found[0]) == "ktop/")
    }

    @Test("Tab on a finished command word picks the exact command")
    func exactCommandIndex() {
        let list = ["cd", "cmux-dev", "clean-diff"].map {
            TerminalCompletionCandidate(kind: .command, title: $0, insertion: $0)
        }
        #expect(TerminalCompletionInline.exactCommandIndex(word: "cd", isCommandPosition: true, candidates: list) == 0)
        #expect(TerminalCompletionInline.exactCommandIndex(word: "cm", isCommandPosition: true, candidates: list) == nil)
        #expect(TerminalCompletionInline.exactCommandIndex(word: "cd", isCommandPosition: false, candidates: list) == nil)
        #expect(TerminalCompletionInline.exactCommandIndex(word: "", isCommandPosition: true, candidates: list) == nil)
    }

    private func makeHome() throws -> String {
        let root = NSTemporaryDirectory() + "cmux-completion-\(UUID().uuidString)"
        for name in ["Desktop", "Documents", "models", "anaconda_projects", "docs"] {
            try FileManager.default.createDirectory(atPath: root + "/" + name, withIntermediateDirectories: true)
        }
        return root
    }

    @Test("Prefix matches win over fuzzy ones, so `cd Des` completes inline")
    func prefixBeatsFuzzy() throws {
        let root = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let found = candidates("cd Des", cwd: root)
        #expect(found.map(\.title) == ["Desktop/"])
        #expect(found.first?.replacementText == "Desktop/")
    }

    @Test("Several prefix matches share a common prefix; case-insensitive only as fallback")
    func prefixCaseFallbackAndCommon() throws {
        let root = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let d = candidates("cd D", cwd: root)
        #expect(Set(d.map(\.title)) == ["Desktop/", "Documents/"])
        #expect(TerminalCompletionInline.commonPrefixSuffix(rawWord: "D", candidates: d) == "e")
        // `des` matches nothing case-sensitively, so the case-insensitive prefix wins.
        #expect(candidates("cd des", cwd: root).map(\.title) == ["Desktop/"])
        // No prefix at all: fuzzy fallback still works.
        #expect(candidates("cd dtp", cwd: root).map(\.title) == ["Desktop/"])
    }

    @Test("`cd ` lists only unique directories, never commands")
    func cdArgumentIsFreshAndUnique() async throws {
        let root = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let context = TerminalCompletionContext.parse(buffer: "cd ", caret: 3)
        let found = await TerminalCompletionProviders.candidates(for: context, cwd: root, isCancelled: { false })
            .filter { $0.kind != .history }
        #expect(found.allSatisfy { $0.kind == .directory })
        #expect(Set(found.map(\.id)).count == found.count)
        #expect(found.count == 5)
    }
}
