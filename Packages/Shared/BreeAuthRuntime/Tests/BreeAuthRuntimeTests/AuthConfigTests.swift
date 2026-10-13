import BREEAuthCore
import Testing
@testable import BreeAuthRuntime

@Suite struct AuthConfigTests {
    @Test func productionUsesStackWhitelistedBreeDomain() {
        let config = AuthConfig(environment: .production)

        #expect(config.magicLinkCallbackURL == "https://github.com/ecyx00/bree/auth/callback")
        #expect(config.apiBaseURL == "https://github.com/ecyx00/bree")
    }
}
