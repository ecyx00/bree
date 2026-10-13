import Testing
import BreeCore

@Suite("Workspace group identity resolution")
struct WorkspaceGroupIdentityResolutionTests {
    @Test("normalizes either accepted alias")
    func normalizesAliases() throws {
        let external = try WorkspaceGroupIdentityResolution(
            externalID: .string("  repo:bree  ")
        )
        #expect(external.value == "repo:bree")

        let retry = try WorkspaceGroupIdentityResolution(
            idempotencyKey: .string(" repo:bree ")
        )
        #expect(retry.value == "repo:bree")
    }

    @Test("accepts matching aliases after normalization")
    func matchingAliases() throws {
        let resolution = try WorkspaceGroupIdentityResolution(
            externalID: .string("repo:bree"),
            idempotencyKey: .string(" repo:bree ")
        )
        #expect(resolution.value == "repo:bree")
    }

    @Test("omitted and null-equivalent inputs produce no identity")
    func absentInputs() throws {
        let resolution = try WorkspaceGroupIdentityResolution()
        #expect(resolution.value == nil)
    }

    @Test("rejects malformed, blank, and mismatched inputs")
    func validationErrors() {
        #expect(throws: WorkspaceGroupIdentityResolution.ValidationError.nonString(field: .externalID)) {
            try WorkspaceGroupIdentityResolution(externalID: .invalid)
        }
        #expect(throws: WorkspaceGroupIdentityResolution.ValidationError.empty(field: .idempotencyKey)) {
            try WorkspaceGroupIdentityResolution(idempotencyKey: .string(" \n "))
        }
        #expect(throws: WorkspaceGroupIdentityResolution.ValidationError.mismatchedAliases) {
            try WorkspaceGroupIdentityResolution(
                externalID: .string("repo:a"),
                idempotencyKey: .string("repo:b")
            )
        }
    }
}
