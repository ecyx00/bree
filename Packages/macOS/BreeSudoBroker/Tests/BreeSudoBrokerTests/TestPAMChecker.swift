@testable import BreeSudoBroker

struct TestPAMChecker: SudoPAMChecking {
    let enabled: Bool

    func touchIDIsEnabled() -> Bool { enabled }
}
