import BreeTerminalCore
import Testing

@Suite struct GhosttyWorkingDirectoryResolverTests {
    private let home = "/Users/tester"
    private let processDirectory = "/Applications/bree.app"

    @Test(arguments: [nil, "", "  ", "relative/path"] as [String?])
    func absentOrInvalidValuesFallBackToHome(_ configuredValue: String?) {
        #expect(resolve(configuredValue) == home)
    }

    @Test func homeUsesCurrentUserHomeDirectory() {
        #expect(resolve("home") == home)
    }

    @Test func inheritUsesProcessWorkingDirectory() {
        #expect(resolve("inherit") == processDirectory)
    }

    @Test func tildePathExpandsAgainstCurrentUserHomeDirectory() {
        #expect(resolve("~/Projects/bree") == "/Users/tester/Projects/bree")
    }

    @Test func absolutePathPassesThrough() {
        #expect(resolve("/Volumes/Work/bree") == "/Volumes/Work/bree")
    }

    @Test func invalidProcessDirectoryFallsBackToHome() {
        #expect(
            GhosttyWorkingDirectoryResolver(
                homeDirectory: home,
                processWorkingDirectory: "relative/path"
            ).resolve(configuredValue: "inherit") == home
        )
    }

    private func resolve(_ configuredValue: String?) -> String {
        GhosttyWorkingDirectoryResolver(
            homeDirectory: home,
            processWorkingDirectory: processDirectory
        ).resolve(configuredValue: configuredValue)
    }
}
