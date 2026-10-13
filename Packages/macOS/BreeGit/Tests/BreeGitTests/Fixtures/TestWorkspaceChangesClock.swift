import Foundation
@testable import BreeGit

actor TestWorkspaceChangesClock: WorkspaceChangesClock {
    private var instant: Duration = .zero

    func now() -> Duration {
        instant
    }

    func advance(by duration: Duration) {
        instant += duration
    }
}
