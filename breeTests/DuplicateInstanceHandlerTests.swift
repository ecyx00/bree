import Foundation
import Testing

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

@Suite("Duplicate instance handling")
struct DuplicateInstanceHandlerTests {
    @Test("only the bree executable is considered a duplicate")
    func onlyBreeExecutableMatches() {
        let app = URL(fileURLWithPath: "/Applications/bree.app/Contents/MacOS/bree")
        let cli = URL(fileURLWithPath: "/Applications/bree.app/Contents/Resources/bin/bree")
        #expect(!AppDelegate.isDuplicateApplicationExecutable(nil, mainExecutableURL: app))
        #expect(!AppDelegate.isDuplicateApplicationExecutable(app, mainExecutableURL: nil))
        let helper = URL(fileURLWithPath: "/usr/bin/osascript")

        #expect(AppDelegate.isDuplicateApplicationExecutable(app, mainExecutableURL: app))
        #expect(!AppDelegate.isDuplicateApplicationExecutable(cli, mainExecutableURL: app))
        #expect(!AppDelegate.isDuplicateApplicationExecutable(helper, mainExecutableURL: app))
    }
}
