import BreeFoundation
import Foundation
import BreeFoundation

struct BreeTopProcessInfo: Sendable {
    let pid: Int
    let processIdentity: AgentPIDProcessIdentity?
    let parentPID: Int
    let name: String
    let path: String?
    let ttyDevice: Int64?
    let breeWorkspaceID: UUID?
    let breeSurfaceID: UUID?
    let breeAttributionReason: String?
    let processGroupID: Int?
    let terminalProcessGroupID: Int?
    var cpuPercent: Double
    let memoryBytes: Int64
    let memorySource: BreeTopProcessMemorySource
    let residentBytes: Int64
    let residentMemorySource: BreeTopProcessMemorySource
    let virtualBytes: Int64
    let threadCount: Int

    init(
        pid: Int,
        processIdentity: AgentPIDProcessIdentity? = nil,
        parentPID: Int,
        name: String,
        path: String?,
        ttyDevice: Int64?,
        breeWorkspaceID: UUID?,
        breeSurfaceID: UUID?,
        breeAttributionReason: String?,
        processGroupID: Int?,
        terminalProcessGroupID: Int?,
        cpuPercent: Double,
        memoryBytes: Int64? = nil,
        memorySource: BreeTopProcessMemorySource? = nil,
        residentBytes: Int64,
        residentMemorySource: BreeTopProcessMemorySource = .residentSize,
        virtualBytes: Int64,
        threadCount: Int
    ) {
        self.pid = pid
        self.processIdentity = processIdentity
        self.parentPID = parentPID
        self.name = name
        self.path = path
        self.ttyDevice = ttyDevice
        self.breeWorkspaceID = breeWorkspaceID
        self.breeSurfaceID = breeSurfaceID
        self.breeAttributionReason = breeAttributionReason
        self.processGroupID = processGroupID
        self.terminalProcessGroupID = terminalProcessGroupID
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes ?? residentBytes
        self.memorySource = memorySource
            ?? (memoryBytes == nil ? .residentSize : .physicalFootprint)
        self.residentBytes = residentBytes
        self.residentMemorySource = residentMemorySource
        self.virtualBytes = virtualBytes
        self.threadCount = threadCount
    }

    var isTerminalForegroundProcessGroup: Bool {
        guard let processGroupID, let terminalProcessGroupID else { return false }
        return processGroupID == terminalProcessGroupID
    }
}
