import BREEAuthCore
import BreeAuthRuntime
import Testing

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

#if DEBUG
/// Session priming refreshes teams whenever `BREE_UITEST_AUTH_FIXTURE_TEAMS`
/// is set, so every team call in a fixture-teams launch must stay off the
/// live client, even when the value is malformed.
@Suite("UI test fixture teams client")
struct UITestFixtureTeamsAuthClientTests {
    @Test func malformedTeamsStillKeepTeamCallsOffTheLiveClient() async throws {
        let live = TeamChangeAuthClient()
        let client = UITestFixtureTeamsAuthClient.wrapping(live, environment: [
            "BREE_UITEST_AUTH_FIXTURE": "1",
            "BREE_UITEST_AUTH_FIXTURE_TEAMS": "not a team list",
        ])

        #expect(try await client.listTeams().isEmpty)
        try await client.setSelectedTeam(id: nil)
        #expect(await live.selectCount == 0)
    }

    @Test func launchesWithoutFixtureTeamsUseTheLiveClient() async throws {
        let live = TeamChangeAuthClient()
        let client = UITestFixtureTeamsAuthClient.wrapping(live, environment: [
            "BREE_UITEST_AUTH_FIXTURE": "1",
        ])

        #expect(try await client.listTeams().map(\.id) == ["team-a", "team-b"])
    }
}
#endif
