import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct PinnedFilesStoreTests {
    private func makeStore() -> (PinnedFilesStore, UserDefaults, String) {
        let suite = "PinnedFilesStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (PinnedFilesStore(defaults: defaults), defaults, suite)
    }

    @Test func startsEmpty() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(store.pins(forRoot: "/tmp/project").isEmpty)
        #expect(defaults.dictionary(forKey: PinnedFilesStore.defaultsKey) == nil)
    }

    @Test func pinsAreStoredRelativeToTheProjectRoot() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(store.pin(path: "/tmp/project/docs/plan.md", root: "/tmp/project"))
        #expect(store.pins(forRoot: "/tmp/project") == ["docs/plan.md"])
        #expect(store.isPinned(path: "/tmp/project/docs/plan.md", root: "/tmp/project"))
        let raw = defaults.dictionary(forKey: PinnedFilesStore.defaultsKey) as? [String: [String]]
        #expect(raw?["/tmp/project"] == ["docs/plan.md"])
    }

    @Test func pinningTwiceKeepsOneEntryAndOrderIsPinOrder() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(store.pin(path: "/tmp/p/b.md", root: "/tmp/p"))
        #expect(store.pin(path: "/tmp/p/a.md", root: "/tmp/p"))
        #expect(!store.pin(path: "/tmp/p/b.md", root: "/tmp/p"))
        #expect(store.pins(forRoot: "/tmp/p") == ["b.md", "a.md"])
    }

    @Test func projectsDoNotShareAndFilesOutsideTheRootAreRejected() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.pin(path: "/tmp/one/x.md", root: "/tmp/one")
        #expect(store.pins(forRoot: "/tmp/two").isEmpty)
        #expect(!store.pin(path: "/tmp/other/y.md", root: "/tmp/one"))
        #expect(!store.pin(path: "/tmp/one", root: "/tmp/one"))
        #expect(!store.pin(path: "/tmp/onefoo/z.md", root: "/tmp/one"))
    }

    @Test func unpinningTheLastFileRemovesTheProjectKey() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.pin(path: "/tmp/p/a.md", root: "/tmp/p")
        store.unpin(path: "/tmp/p/a.md", root: "/tmp/p")
        #expect(store.pins(forRoot: "/tmp/p").isEmpty)
        let raw = defaults.dictionary(forKey: PinnedFilesStore.defaultsKey) as? [String: [String]]
        #expect(raw?["/tmp/p"] == nil)
    }

    @Test func unpinByRelativePathWorksForMissingFiles() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.pin(path: "/tmp/p/gone.md", root: "/tmp/p")
        store.unpin(relativePath: "gone.md", root: "/tmp/p")
        #expect(store.pins(forRoot: "/tmp/p").isEmpty)
    }

    @Test func projectRootIsTheNearestGitAncestorElseTheDirectory() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pins-root-\(UUID().uuidString)")
        let nested = base.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(PinnedFilesStore.projectRoot(forDirectory: nested.path) == nested.standardizedFileURL.path)
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("a/.git"), withIntermediateDirectories: true
        )
        #expect(
            PinnedFilesStore.projectRoot(forDirectory: nested.path)
                == base.appendingPathComponent("a").standardizedFileURL.path
        )
    }

    @Test func collapsedStateIsPersistedAndDefaultsToExpanded() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!store.isSectionCollapsed)
        store.isSectionCollapsed = true
        #expect(store.isSectionCollapsed)
    }
}
