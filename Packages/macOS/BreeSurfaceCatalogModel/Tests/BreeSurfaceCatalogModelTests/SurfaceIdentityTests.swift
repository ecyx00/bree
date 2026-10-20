import Foundation
import Testing
@testable import BreeSurfaceCatalogModel

@Suite struct SurfaceIdentityTests {
    @Test func machineIDRoundTripsThroughItsWireForm() {
        #expect(SurfaceMachineID(rawValue: "local") == .local)
        #expect(SurfaceMachineID(rawValue: "vm-1") == .remote("vm-1"))
        #expect(SurfaceMachineID.remote("vm-1").rawValue == "vm-1")
        #expect(SurfaceMachineID.local.isLocal)
        #expect(SurfaceMachineID.remote("vm-1").remoteMachineID == "vm-1")
    }
}
