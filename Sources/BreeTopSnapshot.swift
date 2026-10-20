import Darwin
import Foundation

struct BreeTopResourceSummary: Sendable {
    var cpuPercent: Double = 0
    var memoryBytes: Int64 = 0
    var residentBytes: Int64 = 0
    var virtualBytes: Int64 = 0
    var processCount: Int = 0
    var pids: [Int] = []
    var missingPIDs: [Int] = []
    var memorySourceFallbackPIDs: [Int] = []
    var residentMemorySourceFallbackPIDs: [Int] = []
    var unavailableMemoryPIDs: [Int] = []
    var unavailableResidentMemoryPIDs: [Int] = []

    func payload() -> [String: Any] {
        [
            "cpu_percent": cpuPercent,
            "memory_bytes": memoryBytes,
            "resident_bytes": residentBytes,
            "virtual_bytes": virtualBytes,
            "process_count": processCount,
            "pids": pids,
            "missing_pids": missingPIDs,
            "memory_source_fallback_pids": memorySourceFallbackPIDs,
            "memory_source_fallback_count": memorySourceFallbackPIDs.count,
            "resident_memory_source_fallback_pids": residentMemorySourceFallbackPIDs,
            "resident_memory_source_fallback_count": residentMemorySourceFallbackPIDs.count,
            "unavailable_memory_pids": unavailableMemoryPIDs,
            "unavailable_memory_count": unavailableMemoryPIDs.count,
            "unavailable_resident_memory_pids": unavailableResidentMemoryPIDs,
            "unavailable_resident_memory_count": unavailableResidentMemoryPIDs.count
        ]
    }

    func attributedPayload(sharedAcross occurrenceCount: Int) -> [String: Any] {
        guard occurrenceCount > 1 else { return payload() }
        var attributed = self
        attributed.cpuPercent /= Double(occurrenceCount)
        attributed.memoryBytes = attributed.memoryBytes / Int64(occurrenceCount)
        attributed.residentBytes = attributed.residentBytes / Int64(occurrenceCount)
        attributed.virtualBytes = attributed.virtualBytes / Int64(occurrenceCount)
        return attributed.payload()
    }
}

enum BreeTopProcessMemorySource: String, Sendable {
    case physicalFootprint = "proc_pid_rusage.RUSAGE_INFO_V4.ri_phys_footprint"
    case residentSize = "proc_pidinfo.PROC_PIDTASKINFO.pti_resident_size"
    case rusageResidentSize = "proc_pid_rusage.RUSAGE_INFO_V4.ri_resident_size"
    case mixed
    case unavailable
}

struct BreeTopProcessScope: Sendable, Equatable {
    let workspaceID: UUID?
    let surfaceID: UUID?
    let attributionReason: String

    init(workspaceID: UUID?, surfaceID: UUID?, attributionReason: String) {
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.attributionReason = attributionReason
    }
}

// All stored indexes and records are immutable after construction.
final class BreeTopProcessSnapshot: @unchecked Sendable {
    /// Keeps process-tree construction and downstream JSON encoding within the
    /// stack available to control-socket worker threads.
    private static let maximumProcessTreeDepth = 32

    let sampledAt: Date
    let captureIsAvailable: Bool
    let enumerationIsComplete: Bool
    let enumerationMissingProcessCount: Int
    private let includesProcessDetails: Bool
    let includesResources: Bool
    private let includesBREEScope: Bool
    let processesByPID: [Int: BreeTopProcessInfo]
    private let childrenByParentPID: [Int: [Int]]
    private let pidsByTTYDevice: [Int64: [Int]]
    private let pidsByBREESurfaceID: [UUID: [Int]]
    private let pidsByProcessGroupID: [Int: [Int]]
    private let residentMemorySources: [BreeTopProcessMemorySource]

    init(
        processes: [BreeTopProcessInfo],
        sampledAt: Date,
        includesProcessDetails: Bool,
        includesBREEScope: Bool = true,
        includesResources: Bool = true,
        enumerationIsComplete: Bool = true,
        enumerationMissingProcessCount: Int = 0,
        captureIsAvailable: Bool = true
    ) {
        self.captureIsAvailable = captureIsAvailable
        self.enumerationIsComplete = enumerationIsComplete && enumerationMissingProcessCount == 0
        self.enumerationMissingProcessCount = max(0, enumerationMissingProcessCount)
        self.sampledAt = sampledAt
        self.includesProcessDetails = includesProcessDetails
        self.includesBREEScope = includesBREEScope
        self.includesResources = includesResources
        var processMap: [Int: BreeTopProcessInfo] = [:]
        processMap.reserveCapacity(processes.count)
        for process in processes {
            processMap[process.pid] = process
        }
        self.processesByPID = processMap
        self.residentMemorySources = Self.sortedMemorySources(
            in: processMap.values.map(\.residentMemorySource)
        )

        var children: [Int: [Int]] = [:]
        var ttyMap: [Int64: [Int]] = [:]
        var breeSurfaceMap: [UUID: [Int]] = [:]
        var processGroupMap: [Int: [Int]] = [:]
        for process in processMap.values {
            if process.parentPID > 0 {
                children[process.parentPID, default: []].append(process.pid)
            }
            if let ttyDevice = process.ttyDevice {
                ttyMap[ttyDevice, default: []].append(process.pid)
            }
            if let breeSurfaceID = process.breeSurfaceID {
                breeSurfaceMap[breeSurfaceID, default: []].append(process.pid)
            }
            if let processGroupID = process.processGroupID {
                processGroupMap[processGroupID, default: []].append(process.pid)
            }
        }
        self.childrenByParentPID = children.mapValues { $0.sorted() }
        self.pidsByTTYDevice = ttyMap.mapValues { $0.sorted() }
        self.pidsByBREESurfaceID = breeSurfaceMap.mapValues { $0.sorted() }
        self.pidsByProcessGroupID = processGroupMap.mapValues { $0.sorted() }
    }

    func samplePayload() -> [String: Any] {
        let residentMemorySourceNames = residentMemorySources.map(\.rawValue)
        return [
            "sampled_at": ISO8601DateFormatter().string(from: sampledAt),
            "source": "proc_listallpids+proc_pidinfo+sysctl(KERN_PROC_PID)",
            "cpu_source": "proc_pidinfo.PROC_PIDTASKINFO.pti_total_user+pti_total_system",
            "memory_source": BreeTopProcessMemorySource.physicalFootprint.rawValue,
            "memory_fallback_source": BreeTopProcessMemorySource.residentSize.rawValue,
            "resident_memory_source": Self.summaryMemorySource(residentMemorySources).rawValue,
            "resident_memory_sources": residentMemorySourceNames,
            "resident_memory_fallback_source": BreeTopProcessMemorySource.rusageResidentSize.rawValue,
            "process_details": includesProcessDetails,
            "resource_details": includesResources,
            "bree_scope": includesBREEScope,
            "enumeration_complete": enumerationIsComplete,
            "enumeration_missing_process_count": enumerationMissingProcessCount
        ]
    }

    var hasBREEScope: Bool {
        includesBREEScope
    }

    private static func sortedMemorySources(
        in sources: [BreeTopProcessMemorySource]
    ) -> [BreeTopProcessMemorySource] {
        [
            .physicalFootprint,
            .residentSize,
            .rusageResidentSize,
            .unavailable
        ].filter { source in
            sources.contains(source)
        }
    }

    private static func summaryMemorySource(
        _ sources: [BreeTopProcessMemorySource]
    ) -> BreeTopProcessMemorySource {
        let concreteSources = sources.filter { $0 != .unavailable }
        guard !concreteSources.isEmpty else { return .unavailable }
        guard concreteSources.count == 1, let source = concreteSources.first else {
            return .mixed
        }
        return source
    }

    func pids(forTTYName ttyName: String) -> Set<Int> {
        guard let device = Self.deviceIdentifier(forTTYName: ttyName) else {
            return []
        }
        return pids(forTTYDevice: device)
    }

    func pids(forTTYDevice ttyDevice: Int64) -> Set<Int> {
        Set(pidsByTTYDevice[ttyDevice] ?? [])
    }

    func pids(forBREESurfaceID surfaceID: UUID) -> Set<Int> {
        Set(pidsByBREESurfaceID[surfaceID] ?? [])
    }

    /// Splits a surface's TTY population into processes bree can prove it owns and
    /// processes that merely share the TTY device.
    ///
    /// Sharing a TTY is not ownership: a process reparented to launchd keeps the
    /// controlling TTY of the terminal it was launched from, so a detached REPL or dev
    /// server would otherwise be summed into the surface's memory.
    /// See https://github.com/ecyx00/bree/issues/11004.
    ///
    /// - Parameters:
    ///   - ttyPIDs: every PID sharing the surface's TTY device.
    ///   - surfaceID: the surface being annotated, when it has an identifier.
    ///   - breeOwnedPIDs: the window's app processes and their descendants, used as launch
    ///     evidence for a process whose parent sits off the TTY.
    ///   - provenPIDs: PIDs already proven through the bree-scoped process tree.
    /// - Returns: the proven set, the unattributed set, and the reason for each PID.
    func ttyOwnership(
        ttyPIDs: Set<Int>,
        surfaceID: UUID?,
        breeOwnedPIDs: Set<Int>,
        provenPIDs: Set<Int> = []
    ) -> BreeTopTTYOwnership {
        var ownershipProcesses: [Int: BreeTopTTYOwnershipProcess] = [:]
        ownershipProcesses.reserveCapacity(ttyPIDs.count)
        for pid in ttyPIDs {
            guard let process = processesByPID[pid] else { continue }
            ownershipProcesses[pid] = BreeTopTTYOwnershipProcess(
                pid: process.pid,
                parentPID: process.parentPID,
                processGroupID: process.processGroupID,
                breeSurfaceID: process.breeSurfaceID
            )
        }
        return BreeTopTTYOwnershipResolver(breeOwnedPIDs: breeOwnedPIDs).resolve(
            candidates: ttyPIDs,
            processes: ownershipProcesses,
            surfaceID: surfaceID,
            provenPIDs: provenPIDs
        )
    }

    func pids(forProcessGroupID processGroupID: Int) -> Set<Int> {
        Set(pidsByProcessGroupID[processGroupID] ?? [])
    }

    func breeScopedProcesses() -> [BreeTopProcessInfo] {
        processesByPID.values
            .filter { $0.breeWorkspaceID != nil && $0.breeSurfaceID != nil }
            .sorted { $0.pid < $1.pid }
    }

    func process(pid: Int) -> BreeTopProcessInfo? {
        processesByPID[pid]
    }

    func expandedPIDs(rootPIDs: Set<Int>) -> Set<Int> {
        var result: Set<Int> = []
        var stack = Array(rootPIDs.filter { $0 > 0 })

        while let pid = stack.popLast() {
            guard result.insert(pid).inserted else { continue }
            stack.append(contentsOf: childrenByParentPID[pid] ?? [])
        }

        return result
    }

    func agentHibernationProcessScope(
        panelProcessIDs: Set<Int>,
        agentProcessIDs: Set<Int>
    ) -> RestorableAgentSessionIndex.HibernationProcessScope {
        guard enumerationIsComplete else { return ([], [], true) }
        let maximumProcessCount = AgentHibernationController.maximumScopedProcessTerminationCount
        func appendBounded<S: Sequence>(
            _ processIDs: S,
            to values: inout Set<Int>
        ) -> Bool where S.Element == Int {
            for processID in processIDs {
                guard processID > 0, !values.contains(processID) else { continue }
                guard values.count < maximumProcessCount else { return true }
                values.insert(processID)
            }
            return false
        }
        func boundedExpandedPIDs(
            rootPIDs: Set<Int>
        ) -> (values: Set<Int>, exceeded: Bool) {
            var values: Set<Int> = []
            var stack: [Int] = []
            stack.reserveCapacity(min(rootPIDs.count, maximumProcessCount))
            for rootPID in rootPIDs {
                guard rootPID > 0, !values.contains(rootPID) else { continue }
                guard values.count < maximumProcessCount else {
                    return (values, true)
                }
                values.insert(rootPID)
                stack.append(rootPID)
            }
            while let processID = stack.popLast() {
                for childProcessID in childrenByParentPID[processID] ?? [] {
                    guard childProcessID > 0, !values.contains(childProcessID) else {
                        continue
                    }
                    guard values.count < maximumProcessCount else {
                        return (values, true)
                    }
                    values.insert(childProcessID)
                    stack.append(childProcessID)
                }
            }
            return (values, false)
        }

        var boundedPanelProcessIDs: Set<Int> = []
        let panelProcessIDsExceeded = appendBounded(
            panelProcessIDs,
            to: &boundedPanelProcessIDs
        )
        var boundedAgentProcessIDs: Set<Int> = []
        let agentProcessIDsExceeded = appendBounded(
            agentProcessIDs,
            to: &boundedAgentProcessIDs
        )
        if panelProcessIDsExceeded || agentProcessIDsExceeded {
            var boundedTerminationProcessIDs: Set<Int> = []
            _ = appendBounded(boundedAgentProcessIDs, to: &boundedTerminationProcessIDs)
            return (
                boundedPanelProcessIDs,
                boundedTerminationProcessIDs,
                true
            )
        }

        let boundedAgentRoots = boundedAgentProcessIDs
        let terminalDevices = Set(boundedAgentRoots.compactMap {
            processesByPID[$0]?.ttyDevice
        })
        var boundedTerminalProcessIDs: Set<Int> = []
        var terminalProcessIDsExceeded = false
        for terminalDevice in terminalDevices {
            terminalProcessIDsExceeded = appendBounded(
                pidsByTTYDevice[terminalDevice] ?? [],
                to: &boundedTerminalProcessIDs
            )
            if terminalProcessIDsExceeded {
                break
            }
        }
        var boundedObservedPanelProcessIDs: Set<Int> = []
        let panelObservationExceeded = appendBounded(
            boundedPanelProcessIDs,
            to: &boundedObservedPanelProcessIDs
        ) || appendBounded(
            boundedTerminalProcessIDs,
            to: &boundedObservedPanelProcessIDs
        )
        if terminalProcessIDsExceeded || panelObservationExceeded {
            var boundedTerminationProcessIDs: Set<Int> = []
            _ = appendBounded(boundedAgentRoots, to: &boundedTerminationProcessIDs)
            return (
                boundedObservedPanelProcessIDs,
                boundedTerminationProcessIDs,
                true
            )
        }

        let observedPanelProcessIDs = boundedObservedPanelProcessIDs
        let descendantCollector = boundedExpandedPIDs(
            rootPIDs: boundedAgentRoots
        )
        if descendantCollector.exceeded {
            return (
                observedPanelProcessIDs,
                descendantCollector.values,
                true
            )
        }
        let descendantProcessIDs = descendantCollector.values
        var boundedAllowedProcessIDs: Set<Int> = []
        var scopeExceeded = appendBounded(
            descendantProcessIDs,
            to: &boundedAllowedProcessIDs
        )

        for rootProcessID in boundedAgentRoots {
            var currentProcessID = rootProcessID
            var visitedProcessIDs: Set<Int> = []
            while visitedProcessIDs.insert(currentProcessID).inserted {
                guard let parentProcessID = processesByPID[currentProcessID]?.parentPID,
                      observedPanelProcessIDs.contains(parentProcessID) else {
                    break
                }
                guard visitedProcessIDs.count < maximumProcessCount else {
                    scopeExceeded = true
                    break
                }
                if appendBounded(
                    [parentProcessID],
                    to: &boundedAllowedProcessIDs
                ) {
                    scopeExceeded = true
                    break
                }
                currentProcessID = parentProcessID
            }
            if scopeExceeded {
                break
            }
        }
        if scopeExceeded {
            var boundedTerminationProcessIDs: Set<Int> = []
            _ = appendBounded(descendantProcessIDs, to: &boundedTerminationProcessIDs)
            return (
                observedPanelProcessIDs,
                boundedTerminationProcessIDs,
                true
            )
        }

        let processGroupIDs = Set(descendantProcessIDs.compactMap {
            processesByPID[$0]?.processGroupID
        }).filter { $0 > 1 }
        var boundedProcessGroupMemberIDs: Set<Int> = []
        var processGroupMembersExceeded = false
        for processGroupID in processGroupIDs {
            processGroupMembersExceeded = appendBounded(
                pidsByProcessGroupID[processGroupID] ?? [],
                to: &boundedProcessGroupMemberIDs
            )
            if processGroupMembersExceeded {
                break
            }
        }
        var boundedTerminationProcessIDs: Set<Int> = []
        let terminationProcessIDsExceeded = appendBounded(
            descendantProcessIDs,
            to: &boundedTerminationProcessIDs
        ) || appendBounded(
            boundedProcessGroupMemberIDs,
            to: &boundedTerminationProcessIDs
        )
        if processGroupMembersExceeded || terminationProcessIDsExceeded {
            return (
                observedPanelProcessIDs,
                boundedTerminationProcessIDs,
                true
            )
        }
        let processGroupMemberIDs = boundedProcessGroupMemberIDs
        let terminationProcessIDs = boundedTerminationProcessIDs
        let terminationTTYDevices = terminationProcessIDs.compactMap {
            processesByPID[$0]?.ttyDevice
        }
        let hasCompleteTerminationTTYEvidence = terminationProcessIDs.isEmpty ||
            (
                terminationTTYDevices.count == terminationProcessIDs.count &&
                    Set(terminationTTYDevices).count == 1
            )

        let hasCompleteAgentRoots =
            !boundedAgentRoots.isEmpty &&
            boundedAgentRoots.isSubset(of: terminationProcessIDs)
        let hasTerminalEvidence = boundedAgentRoots.allSatisfy {
            processesByPID[$0]?.ttyDevice != nil
        }
        let hasCompleteProcessGroups = processGroupIDs.allSatisfy { processGroupID in
            processesByPID[processGroupID]?.processGroupID == processGroupID
        }
        let hasLiveBackgroundWork = !agentBackgroundWorkProcessIDs(
            agentRootPIDs: boundedAgentRoots,
            descendantProcessIDs: descendantProcessIDs
        ).isEmpty
        return (
            observedPanelProcessIDs,
            terminationProcessIDs,
            hasLiveBackgroundWork ||
                !hasCompleteAgentRoots ||
                !hasTerminalEvidence ||
                !hasCompleteTerminationTTYEvidence ||
                processGroupIDs.isEmpty ||
                !hasCompleteProcessGroups ||
                !processGroupMemberIDs.isSubset(of: boundedAllowedProcessIDs) ||
                !observedPanelProcessIDs.isSubset(of: boundedAllowedProcessIDs)
        )
    }

    func descendantPIDs(rootPID: Int, includeRoot: Bool = false) -> Set<Int> {
        guard rootPID > 0 else { return [] }

        var result: Set<Int> = includeRoot && processesByPID[rootPID] != nil ? [rootPID] : []
        var visited: Set<Int> = []
        var stack = childrenByParentPID[rootPID] ?? []
        stack.append(contentsOf: Self.listedChildPIDs(parentPID: rootPID))
        while let pid = stack.popLast() {
            guard visited.insert(pid).inserted else { continue }
            guard result.insert(pid).inserted else { continue }
            stack.append(contentsOf: childrenByParentPID[pid] ?? [])
            stack.append(contentsOf: Self.listedChildPIDs(parentPID: pid))
        }
        return result
    }

    private static func listedChildPIDs(parentPID: Int) -> [Int] {
        guard parentPID > 0 else { return [] }

        let pidStride = MemoryLayout<pid_t>.stride
        var capacity = 16
        var lastChildren: [Int] = []
        for _ in 0..<4 {
            var pids = Array(repeating: pid_t(), count: capacity)
            let returnedCount = pids.withUnsafeMutableBufferPointer { buffer in
                proc_listchildpids(
                    pid_t(parentPID),
                    buffer.baseAddress,
                    Int32(buffer.count * pidStride)
                )
            }
            guard returnedCount >= 0 else {
                return lastChildren
            }

            let count = min(pids.count, Int(returnedCount))
            lastChildren = pids
                .prefix(count)
                .compactMap { pid in
                    let intPID = Int(pid)
                    return intPID > 0 ? intPID : nil
                }
            if Int(returnedCount) < pids.count {
                return lastChildren
            }
            capacity = max(pids.count * 2, Int(returnedCount) + 16)
        }
        return lastChildren
    }

    func summaryPayload(for pids: Set<Int>, rootPIDs: Set<Int> = []) -> [String: Any] {
        summary(for: pids, rootPIDs: rootPIDs).payload()
    }

    func summary(for pids: Set<Int>, rootPIDs: Set<Int> = []) -> BreeTopResourceSummary {
        let sortedPIDs = pids.filter { $0 > 0 }.sorted()
        var summary = BreeTopResourceSummary()
        summary.pids = sortedPIDs
        summary.missingPIDs = rootPIDs
            .filter { $0 > 0 && processesByPID[$0] == nil }
            .sorted()

        for pid in sortedPIDs {
            guard let process = processesByPID[pid] else { continue }
            summary.cpuPercent += process.cpuPercent
            summary.memoryBytes = Self.clampedAdd(summary.memoryBytes, process.memoryBytes)
            summary.residentBytes = Self.clampedAdd(summary.residentBytes, process.residentBytes)
            summary.virtualBytes = Self.clampedAdd(summary.virtualBytes, process.virtualBytes)
            summary.processCount += 1
            if process.memorySource == .residentSize {
                summary.memorySourceFallbackPIDs.append(pid)
            } else if process.memorySource == .unavailable {
                summary.unavailableMemoryPIDs.append(pid)
            }
            if process.residentMemorySource == .rusageResidentSize {
                summary.residentMemorySourceFallbackPIDs.append(pid)
            } else if process.residentMemorySource == .unavailable {
                summary.unavailableResidentMemoryPIDs.append(pid)
            }
        }

        return summary
    }

    func programSummaryPayload(for pids: Set<Int>) -> [[String: Any]] {
        var aggregates: [String: BreeProgramProcessAggregate] = [:]

        for pid in pids.sorted() {
            guard let process = processesByPID[pid] else { continue }
            let title = process.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let key = title.lowercased()
            if aggregates[key] == nil {
                aggregates[key] = BreeProgramProcessAggregate(id: key, title: title)
            }
            aggregates[key]?.append(process)
        }

        return aggregates.values
            .filter { $0.processIds.count > 1 }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .map { $0.payload() }
    }

    func processTreePayload(for pids: Set<Int>, rootPIDs explicitRootPIDs: Set<Int> = []) -> [[String: Any]] {
        let allowedPIDs = Set(pids.filter { processesByPID[$0] != nil })
        guard !allowedPIDs.isEmpty else { return [] }

        let roots: [Int]
        if explicitRootPIDs.isEmpty {
            roots = allowedPIDs
                .filter { pid in
                    guard let parent = processesByPID[pid]?.parentPID else { return true }
                    return !allowedPIDs.contains(parent)
                }
                .sorted { processSortKey($0) < processSortKey($1) }
        } else {
            let explicit = explicitRootPIDs.filter { allowedPIDs.contains($0) }
            let orphaned = allowedPIDs.filter { pid in
                explicit.contains(pid) || !allowedPIDs.contains(processesByPID[pid]?.parentPID ?? 0)
            }
            roots = Array(orphaned).sorted { processSortKey($0) < processSortKey($1) }
        }

        var pendingRootPIDs = roots
        if pendingRootPIDs.isEmpty {
            pendingRootPIDs = allowedPIDs.sorted { processSortKey($0) < processSortKey($1) }
        }

        var visited: Set<Int> = []
        var rootNodes: [[String: Any]] = []
        var pendingRootIndex = 0
        while visited.count < allowedPIDs.count {
            if pendingRootIndex == pendingRootPIDs.count {
                guard let nextRootPID = allowedPIDs
                    .filter({ !visited.contains($0) })
                    .min(by: { processSortKey($0) < processSortKey($1) }) else {
                    break
                }
                pendingRootPIDs.append(nextRootPID)
            }

            let pid = pendingRootPIDs[pendingRootIndex]
            pendingRootIndex += 1
            if let node = processTreeNode(
                pid: pid,
                allowedPIDs: allowedPIDs,
                rootPIDs: explicitRootPIDs,
                depth: 1,
                pendingRootPIDs: &pendingRootPIDs,
                visited: &visited
            ) {
                rootNodes.append(node)
            }
        }
        return rootNodes
    }

    func topLevelPIDs(for pids: Set<Int>) -> Set<Int> {
        let allowedPIDs = Set(pids.filter { processesByPID[$0] != nil })
        return allowedPIDs.filter { pid in
            guard let parent = processesByPID[pid]?.parentPID else { return true }
            return !allowedPIDs.contains(parent)
        }
    }

    func foregroundProcessGroupIDs(for pids: Set<Int>) -> Set<Int> {
        Set(
            pids.compactMap { pid in
                guard let process = processesByPID[pid],
                      process.isTerminalForegroundProcessGroup else {
                    return nil
                }
                return process.terminalProcessGroupID
            }
        )
    }

    func codingAgentSummaryPayload(for pids: Set<Int>) -> [[String: Any]] {
        var aggregates: [String: BreeCodingAgentProcessAggregate] = [:]

        for pid in pids.sorted() {
            guard let process = processesByPID[pid] else { continue }
            let processArguments = Self.processArgumentsIfNeeded(for: process)
            guard let definition = BreeTaskManagerCodingAgentDefinition.matchingDefinition(
                processName: process.name,
                processPath: process.path,
                arguments: processArguments?.arguments ?? [],
                environment: processArguments?.environment ?? [:]
            ) else { continue }

            if aggregates[definition.id] == nil {
                aggregates[definition.id] = BreeCodingAgentProcessAggregate(definition: definition)
            }
            aggregates[definition.id]?.append(process)
        }

        return BreeTaskManagerCodingAgentDefinition.builtIns.compactMap { definition in
            guard let aggregate = aggregates[definition.id] else { return nil }
            return aggregate.payload()
        }
    }

    private static func processArgumentsIfNeeded(for process: BreeTopProcessInfo) -> BreeTopProcessArguments? {
        guard BreeTaskManagerCodingAgentDefinition.shouldReadArguments(
            processName: process.name,
            processPath: process.path
        ) else { return nil }
        return processArgumentsAndEnvironment(for: process)
    }

    private struct BreeProgramProcessAggregate {
        let id: String
        let title: String
        var cpuPercent: Double = 0
        var memoryBytes: Int64 = 0
        var residentBytes: Int64 = 0
        var processIds: [Int] = []
        var seenProcessIds: Set<Int> = []
        var memorySourceFallbackPIDs: [Int] = []
        var residentMemorySourceFallbackPIDs: [Int] = []
        var unavailableMemoryPIDs: [Int] = []
        var unavailableResidentMemoryPIDs: [Int] = []

        mutating func append(_ process: BreeTopProcessInfo) {
            guard seenProcessIds.insert(process.pid).inserted else { return }
            cpuPercent += process.cpuPercent
            memoryBytes = BreeTopProcessSnapshot.clampedAdd(memoryBytes, process.memoryBytes)
            residentBytes = BreeTopProcessSnapshot.clampedAdd(residentBytes, process.residentBytes)
            processIds.append(process.pid)
            if process.memorySource == .residentSize {
                memorySourceFallbackPIDs.append(process.pid)
            } else if process.memorySource == .unavailable {
                unavailableMemoryPIDs.append(process.pid)
            }
            if process.residentMemorySource == .rusageResidentSize {
                residentMemorySourceFallbackPIDs.append(process.pid)
            } else if process.residentMemorySource == .unavailable {
                unavailableResidentMemoryPIDs.append(process.pid)
            }
        }

        func payload() -> [String: Any] {
            let sortedProcessIds = processIds.sorted()
            return [
                "id": id,
                "name": title,
                "resources": BreeTopResourceSummary(
                    cpuPercent: cpuPercent,
                    memoryBytes: memoryBytes,
                    residentBytes: residentBytes,
                    processCount: sortedProcessIds.count,
                    pids: sortedProcessIds,
                    memorySourceFallbackPIDs: memorySourceFallbackPIDs.sorted(),
                    residentMemorySourceFallbackPIDs: residentMemorySourceFallbackPIDs.sorted(),
                    unavailableMemoryPIDs: unavailableMemoryPIDs.sorted(),
                    unavailableResidentMemoryPIDs: unavailableResidentMemoryPIDs.sorted()
                ).payload()
            ]
        }
    }

    private struct BreeCodingAgentProcessAggregate {
        let definition: BreeTaskManagerCodingAgentDefinition
        var cpuPercent: Double = 0
        var memoryBytes: Int64 = 0
        var residentBytes: Int64 = 0
        var processIds: [Int] = []
        var seenProcessIds: Set<Int> = []
        var memorySourceFallbackPIDs: [Int] = []
        var residentMemorySourceFallbackPIDs: [Int] = []
        var unavailableMemoryPIDs: [Int] = []
        var unavailableResidentMemoryPIDs: [Int] = []

        mutating func append(_ process: BreeTopProcessInfo) {
            guard seenProcessIds.insert(process.pid).inserted else { return }
            cpuPercent += process.cpuPercent
            memoryBytes = BreeTopProcessSnapshot.clampedAdd(memoryBytes, process.memoryBytes)
            residentBytes = BreeTopProcessSnapshot.clampedAdd(residentBytes, process.residentBytes)
            processIds.append(process.pid)
            if process.memorySource == .residentSize {
                memorySourceFallbackPIDs.append(process.pid)
            } else if process.memorySource == .unavailable {
                unavailableMemoryPIDs.append(process.pid)
            }
            if process.residentMemorySource == .rusageResidentSize {
                residentMemorySourceFallbackPIDs.append(process.pid)
            } else if process.residentMemorySource == .unavailable {
                unavailableResidentMemoryPIDs.append(process.pid)
            }
        }

        func payload() -> [String: Any] {
            let sortedProcessIds = processIds.sorted()
            return [
                "id": definition.id,
                "display_name": definition.displayName,
                "asset_name": definition.assetName ?? NSNull(),
                "resources": BreeTopResourceSummary(
                    cpuPercent: cpuPercent,
                    memoryBytes: memoryBytes,
                    residentBytes: residentBytes,
                    processCount: sortedProcessIds.count,
                    pids: sortedProcessIds,
                    memorySourceFallbackPIDs: memorySourceFallbackPIDs.sorted(),
                    residentMemorySourceFallbackPIDs: residentMemorySourceFallbackPIDs.sorted(),
                    unavailableMemoryPIDs: unavailableMemoryPIDs.sorted(),
                    unavailableResidentMemoryPIDs: unavailableResidentMemoryPIDs.sorted()
                ).payload()
            ]
        }
    }

    private func processTreeNode(
        pid: Int,
        allowedPIDs: Set<Int>,
        rootPIDs: Set<Int>,
        depth: Int,
        pendingRootPIDs: inout [Int],
        visited: inout Set<Int>
    ) -> [String: Any]? {
        guard visited.insert(pid).inserted,
              let process = processesByPID[pid] else {
            return nil
        }

        let childPIDs = (childrenByParentPID[pid] ?? [])
            .filter { allowedPIDs.contains($0) }
            .sorted { processSortKey($0) < processSortKey($1) }

        let childNodes: [[String: Any]]
        if depth < Self.maximumProcessTreeDepth {
            childNodes = childPIDs.compactMap {
                processTreeNode(
                    pid: $0,
                    allowedPIDs: allowedPIDs,
                    rootPIDs: rootPIDs,
                    depth: depth + 1,
                    pendingRootPIDs: &pendingRootPIDs,
                    visited: &visited
                )
            }
        } else {
            pendingRootPIDs.append(contentsOf: childPIDs.filter { !visited.contains($0) })
            childNodes = []
        }

        var payload: [String: Any] = [
            "kind": "process",
            "pid": process.pid,
            "ppid": process.parentPID,
            "name": process.name,
            "path": process.path ?? NSNull(),
            "attribution_reason": attributionReason(for: process, allowedPIDs: allowedPIDs, rootPIDs: rootPIDs),
            "thread_count": process.threadCount,
            "memory_source": process.memorySource.rawValue,
            "resident_memory_source": process.residentMemorySource.rawValue,
            "resources": summary(for: [pid]).payload(),
            "children": childNodes
        ]
        if let processClass = BreeTaskManagerRow.ProcessClass.classify(processName: process.name, isAgent: false) {
            payload["class"] = processClass.rawValue
        }
        if let ttyDevice = process.ttyDevice {
            payload["tty_device"] = ttyDevice
        } else {
            payload["tty_device"] = NSNull()
        }
        if let breeWorkspaceID = process.breeWorkspaceID {
            payload["bree_workspace_id"] = breeWorkspaceID.uuidString
        } else {
            payload["bree_workspace_id"] = NSNull()
        }
        if let breeSurfaceID = process.breeSurfaceID {
            payload["bree_surface_id"] = breeSurfaceID.uuidString
        } else {
            payload["bree_surface_id"] = NSNull()
        }
        if let processGroupID = process.processGroupID {
            payload["pgid"] = processGroupID
        } else {
            payload["pgid"] = NSNull()
        }
        if let terminalProcessGroupID = process.terminalProcessGroupID {
            payload["tpgid"] = terminalProcessGroupID
        } else {
            payload["tpgid"] = NSNull()
        }
        return payload
    }

    private func attributionReason(
        for process: BreeTopProcessInfo,
        allowedPIDs: Set<Int>,
        rootPIDs: Set<Int>
    ) -> String {
        if let reason = process.breeAttributionReason {
            return reason
        }
        if rootPIDs.contains(process.pid), isWebKitWebContentProcess(process) {
            return "webview-root-pid"
        }
        if rootPIDs.contains(process.pid) {
            return "explicit-root-pid"
        }
        if allowedPIDs.contains(process.parentPID) {
            return "child-process"
        }
        return "included-process"
    }

    private func isWebKitWebContentProcess(_ process: BreeTopProcessInfo) -> Bool {
        if process.name.localizedCaseInsensitiveContains("WebContent") {
            return true
        }
        return process.path?.localizedCaseInsensitiveContains("com.apple.WebKit.WebContent") == true
    }

    private func processSortKey(_ pid: Int) -> String {
        let process = processesByPID[pid]
        return "\(process?.name ?? ""):\(pid)"
    }

    static func clampedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        if rhs > 0, lhs > Int64.max - rhs {
            return Int64.max
        }
        return lhs + rhs
    }
}
