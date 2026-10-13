import Testing
@testable import BreeSettings

@Test func markerFilesAreVariantAware() {
    #expect(SocketPathMarkerFiles.variant(
        bundleIdentifier: "com.bree.app",
        environment: [:]
    ) == .stable)
    #expect(SocketPathMarkerFiles.variant(
        bundleIdentifier: "com.bree.app.nightly",
        environment: [:]
    ) == .nightly(slug: nil))
    #expect(SocketPathMarkerFiles.variant(
        bundleIdentifier: "com.bree.app.rc",
        environment: [:]
    ) == .rc(slug: nil))
    #expect(SocketPathMarkerFiles.variant(
        bundleIdentifier: "com.bree.app.rc.my-feature",
        environment: [:]
    ) == .rc(slug: "my-feature"))
    #expect(SocketPathMarkerFiles.variant(
        bundleIdentifier: "com.bree.app.debug.agent",
        environment: [:]
    ) == .dev(slug: "agent"))
    #expect(SocketPathMarkerFiles.variant(
        bundleIdentifier: "com.bree.app.debug",
        environment: ["BREE_TAG": "Issue 3542"]
    ) == .dev(slug: "issue-3542"))
    #expect(SocketPathMarkerFiles.variant(
        bundleIdentifier: "com.bree.app.debug",
        environment: ["BREE_TAG": "café"]
    ) == .dev(slug: "caf"))
}

@Test func defaultSocketPathsStayVariantScoped() {
    #expect(SocketPathMarkerFiles.defaultSocketPath(
        bundleIdentifier: "com.bree.app",
        environment: [:],
        isDebugBuild: false,
        stableSocketPath: "/stable/bree.sock"
    ) == "/stable/bree.sock")
    #expect(SocketPathMarkerFiles.defaultSocketPath(
        bundleIdentifier: "com.bree.app.nightly",
        environment: [:],
        isDebugBuild: false,
        stableSocketPath: "/stable/bree.sock"
    ) == "/tmp/bree-nightly.sock")
    #expect(SocketPathMarkerFiles.defaultSocketPath(
        bundleIdentifier: "com.bree.app.rc",
        environment: [:],
        isDebugBuild: false,
        stableSocketPath: "/stable/bree.sock"
    ) == "/tmp/bree-rc.sock")
    #expect(SocketPathMarkerFiles.defaultSocketPath(
        bundleIdentifier: "com.bree.app.rc.candidate1",
        environment: [:],
        isDebugBuild: false,
        stableSocketPath: "/stable/bree.sock"
    ) == "/tmp/bree-rc-candidate1.sock")
    #expect(SocketPathMarkerFiles.defaultSocketPath(
        bundleIdentifier: "com.bree.app.staging.my-feature",
        environment: [:],
        isDebugBuild: false,
        stableSocketPath: "/stable/bree.sock"
    ) == "/tmp/bree-staging-my-feature.sock")
    #expect(SocketPathMarkerFiles.defaultSocketPath(
        bundleIdentifier: "com.bree.app.debug",
        environment: ["BREE_TAG": "Issue 3542"],
        isDebugBuild: false,
        stableSocketPath: "/stable/bree.sock"
    ) == "/tmp/bree-debug-issue-3542.sock")
}
