import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct AttentionChangeRulesTests {
    private let root = "/Users/me/project"

    @Test func ignoresGeneratedAndVcsDirectoriesAnywhereBelowTheRoot() {
        for path in [
            "\(root)/.git/index",
            "\(root)/node_modules/pkg/index.js",
            "\(root)/app/.build/debug/app",
            "\(root)/DerivedData/Build/x.o",
            "\(root)/build/out.bin",
            "\(root)/web/dist/main.js",
            "\(root)/.venv/lib/site.py",
            "\(root)/src/__pycache__/a.pyc",
            "\(root)/.cache/thing",
            "\(root)/.pytest_cache/v/cache",
            "\(root)/.ruff_cache/0.1/x",
            "\(root)/.DS_Store",
        ] {
            #expect(AttentionChangeRules.shouldIgnore(path: path, root: root), "\(path)")
        }
    }

    @Test func keepsRealWorkIncludingHiddenFilesAndLookalikeNames() {
        for path in [
            "\(root)/src/main.swift",
            "\(root)/.env",
            "\(root)/.gitignore",
            "\(root)/.github/workflows/ci.yml",
            "\(root)/builder/notes.md",
            "\(root)/distance.txt",
        ] {
            #expect(!AttentionChangeRules.shouldIgnore(path: path, root: root), "\(path)")
        }
    }

    @Test func ignoresPathsOutsideTheRoot() {
        #expect(AttentionChangeRules.shouldIgnore(path: "/Users/me/other/a.txt", root: root))
        #expect(AttentionChangeRules.shouldIgnore(path: "/Users/me/project-two/a.txt", root: root))
        #expect(AttentionChangeRules.shouldIgnore(path: root, root: root))
    }

    @Test func rootNamedLikeAnIgnoredDirectoryStillWatchesItsContents() {
        #expect(!AttentionChangeRules.shouldIgnore(path: "/work/build/src/a.c", root: "/work/build"))
    }

    @Test func refusesTheFilesystemRootAndTheHomeFolder() {
        #expect(!AttentionChangeRules.isWatchableRoot("/", home: "/Users/me"))
        #expect(!AttentionChangeRules.isWatchableRoot("/Users/me", home: "/Users/me"))
        #expect(!AttentionChangeRules.isWatchableRoot("/Users/me/", home: "/Users/me"))
        #expect(!AttentionChangeRules.isWatchableRoot("relative/dir", home: "/Users/me"))
        #expect(AttentionChangeRules.isWatchableRoot("/Users/me/project", home: "/Users/me"))
    }

    @Test func logCapsAtFiveHundredAndFlagsTruncation() {
        var log = AttentionChangeLog()
        for index in 0..<(AttentionChangeLog.cap + 20) {
            log.record(path: "/p/\(index)", kind: .modified)
        }
        #expect(log.count == AttentionChangeLog.cap)
        #expect(log.isTruncated)
        log.record(path: "/p/0", kind: .deleted)
        #expect(log.entries.first?.kind == .deleted)
        #expect(log.count == AttentionChangeLog.cap)
    }

    @Test func logFoldsRepeatedChangesToOneEntryPerPath() {
        var log = AttentionChangeLog()
        log.record(path: "/p/a", kind: .created)
        log.record(path: "/p/a", kind: .modified)
        #expect(log.entries == [.init(path: "/p/a", kind: .created)])

        log.record(path: "/p/a", kind: .deleted)
        #expect(log.isEmpty)

        log.record(path: "/p/b", kind: .modified)
        log.record(path: "/p/b", kind: .deleted)
        #expect(log.entries == [.init(path: "/p/b", kind: .deleted)])
        log.record(path: "/p/b", kind: .created)
        #expect(log.entries == [.init(path: "/p/b", kind: .modified)])
    }

    @Test func removingAnEntryKeepsTheRemainingIndexConsistent() {
        var log = AttentionChangeLog()
        log.record(path: "/p/a", kind: .created)
        log.record(path: "/p/b", kind: .modified)
        log.record(path: "/p/a", kind: .deleted)
        log.record(path: "/p/b", kind: .deleted)
        #expect(log.entries == [.init(path: "/p/b", kind: .deleted)])
    }
}
