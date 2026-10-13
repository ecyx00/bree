import BreeCloud
import AppKit
import Testing

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

/// The bree-tui client's `remote-probe --json` capabilities travel to the control
/// plane through `vm.bree_remote_info` → `VMClient.openBreeRemote`; the control plane
/// keys the machine host on them, so only well-formed tokens may leave the Mac.
@Suite struct CloudVMBreeTuiClientCapabilityTests {
    @Test func forwardsWellFormedTokensInOrderWithoutDuplicates() {
        let tokens = VMClient.sanitizedClientCapabilities([
            "direct-ws-user-agent",
            " direct-ws-user-agent ",
            "Bad Token!",
            "",
            "UPPER",
            String(repeating: "x", count: 65),
            "other-cap",
        ])
        #expect(tokens == ["direct-ws-user-agent", "other-cap"])
    }

    @Test func capsTheListLikeTheServerValidator() {
        let tokens = VMClient.sanitizedClientCapabilities((0..<20).map { "cap-\($0)" })
        #expect(tokens.count == 16)
        #expect(tokens.first == "cap-0")
        #expect(tokens.last == "cap-15")
    }
}

/// A bree-tui workspace has no `remoteConfiguration`; `workspace.cloud_vm_bind` records
/// its machine so the Machines panel, `bree vm desktop`, and the sidebar cloud button's
/// Base reuse find it the same way they find managed-transport workspaces.
@MainActor
@Suite struct WorkspaceCloudVMBindingTests {
    @Test func normalizedVMIDAcceptsProviderHandlesOnly() {
        #expect(WorkspaceCloudVMBinding.normalizedVMID(" vivid-newt ") == "vivid-newt")
        #expect(WorkspaceCloudVMBinding.normalizedVMID("sc-mt237w1nd7c7673bd03m") == "sc-mt237w1nd7c7673bd03m")
        #expect(WorkspaceCloudVMBinding.normalizedVMID("") == nil)
        #expect(WorkspaceCloudVMBinding.normalizedVMID(nil) == nil)
        #expect(WorkspaceCloudVMBinding.normalizedVMID("bad id") == nil)
        #expect(WorkspaceCloudVMBinding.normalizedVMID("../etc") == nil)
    }

    @Test func boundWorkspaceReportsItsMachineUnderTheManagedKey() {
        let workspace = Workspace()
        workspace.cloudVMBinding = WorkspaceCloudVMBinding(vmID: "vivid-newt", isBase: true)
        let payload = workspace.remoteStatusPayload()
        #expect(payload["managed_cloud_vm_id"] as? String == "vivid-newt")
        #expect(payload["cloud_vm_id"] as? String == "vivid-newt")
        #expect(payload["cloud_vm_base"] as? Bool == true)
        #expect(payload["cloud_vm_transport"] as? String == "bree-remote")
    }

    @Test func unboundWorkspaceReportsNoMachine() {
        let workspace = Workspace()
        let payload = workspace.remoteStatusPayload()
        #expect(payload["managed_cloud_vm_id"] == nil || payload["managed_cloud_vm_id"] is NSNull)
        #expect(payload["cloud_vm_id"] is NSNull)
        #expect(payload["cloud_vm_transport"] is NSNull)
    }
}
