import Darwin
import Foundation

nonisolated let breeTopMemoryDiagnosticDefaultGroupLimit = 12

extension BreeTopProcessSnapshot {
    func memoryDiagnosticPayload(
        appPID: Int = Int(Darwin.getpid()),
        topGroupLimit: Int = breeTopMemoryDiagnosticDefaultGroupLimit,
        attributionByPID: [Int: BreeTopProcessAttribution] = [:]
    ) -> [String: Any] {
        let appResources = summaryPayload(for: [appPID], rootPIDs: [appPID])
        let appProcess = processesByPID[appPID]
        let childPIDs = expandedPIDs(rootPIDs: [appPID]).subtracting([appPID])
            .filter { processesByPID[$0] != nil }
        let childSummary = summary(for: childPIDs)
        let groups = memoryDiagnosticGroups(
            for: childPIDs,
            topGroupLimit: topGroupLimit,
            attributionByPID: attributionByPID
        )
        let topGroup = groups.first

        return [
            "sampled_at": ISO8601DateFormatter().string(from: sampledAt),
            "app": [
                "pid": appPID,
                "name": appProcess?.name ?? "bree",
                "path": appProcess?.path as Any? ?? NSNull(),
                "resources": appResources,
                "physical_footprint_bytes": appProcess?.memoryBytes ?? 0,
                "resident_bytes": appProcess?.residentBytes ?? 0,
                "memory_source": appProcess?.memorySource.rawValue ?? BreeTopProcessMemorySource.unavailable.rawValue,
                "resident_memory_source": appProcess?.residentMemorySource.rawValue ?? BreeTopProcessMemorySource.unavailable.rawValue
            ] as [String: Any],
            "children": [
                "root_pid": appPID,
                "recursive_rss_bytes": childSummary.residentBytes,
                "process_count": childSummary.processCount,
                "pids": childSummary.pids,
                "groups": groups
            ] as [String: Any],
            "summary": memoryDiagnosticSummaryText(
                appFootprintBytes: appProcess?.memoryBytes ?? 0,
                childRSSBytes: childSummary.residentBytes,
                topGroup: topGroup
            )
        ]
    }

    private func memoryDiagnosticGroups(
        for pids: Set<Int>,
        topGroupLimit: Int,
        attributionByPID: [Int: BreeTopProcessAttribution]
    ) -> [[String: Any]] {
        var groups: [String: BreeTopMemoryDiagnosticGroupAccumulator] = [:]
        for pid in pids.sorted() {
            guard let process = processesByPID[pid] else { continue }
            let name = process.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = name.isEmpty ? "pid-\(pid)" : name
            let key = displayName.lowercased()
            if groups[key] == nil {
                groups[key] = BreeTopMemoryDiagnosticGroupAccumulator(id: key, name: displayName)
            }
            groups[key]?.append(
                process: process,
                attribution: nearestBREEAttribution(
                    for: pid,
                    attributionByPID: attributionByPID
                )
            )
        }

        let limit = max(1, topGroupLimit)
        return groups.values
            .sorted {
                if $0.rssBytes != $1.rssBytes {
                    return $0.rssBytes > $1.rssBytes
                }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            .prefix(limit)
            .map { $0.payload() }
    }

    private func nearestBREEAttribution(
        for pid: Int,
        attributionByPID: [Int: BreeTopProcessAttribution]
    ) -> BreeTopProcessAttribution? {
        var visited: Set<Int> = []
        var currentPID = pid
        while currentPID > 0, visited.insert(currentPID).inserted {
            if let attribution = attributionByPID[currentPID] {
                return attribution
            }
            guard let process = processesByPID[currentPID] else { return nil }
            if process.breeWorkspaceID != nil || process.breeSurfaceID != nil {
                return BreeTopProcessAttribution(
                    workspaceID: process.breeWorkspaceID,
                    workspaceRef: nil,
                    paneID: nil,
                    paneRef: nil,
                    surfaceID: process.breeSurfaceID,
                    surfaceRef: nil,
                    surfaceType: nil,
                    reason: process.breeAttributionReason ?? "bree-process-scope"
                )
            }
            currentPID = process.parentPID
        }
        return nil
    }

    private func memoryDiagnosticSummaryText(
        appFootprintBytes: Int64,
        childRSSBytes: Int64,
        topGroup: [String: Any]?
    ) -> String {
        var summary = String.localizedStringWithFormat(
            String(localized: "memoryDiagnostic.summary.base", defaultValue: "%@ app footprint + %@ child RSS"),
            Self.formatDiagnosticBytes(appFootprintBytes),
            Self.formatDiagnosticBytes(childRSSBytes)
        )
        guard let topGroup,
              let name = topGroup["name"] as? String,
              let rssBytes = topGroup["rss_bytes"] as? Int64 ?? (topGroup["rss_bytes"] as? NSNumber)?.int64Value else {
            return summary
        }

        summary += String.localizedStringWithFormat(
            String(localized: "memoryDiagnostic.summary.topGroup", defaultValue: "; top child group: %@ %@"),
            name,
            Self.formatDiagnosticBytes(rssBytes)
        )
        if let groupAttribution = topGroup["group_attribution"] as? [String: Any],
           groupAttribution["kind"] as? String == "common",
           let attribution = groupAttribution["owner"] as? [String: Any],
           let workspace = attribution["workspace_ref"] as? String ?? attribution["workspace_id"] as? String,
           !workspace.isEmpty {
            summary += String.localizedStringWithFormat(
                String(localized: "memoryDiagnostic.summary.workspace", defaultValue: " from workspace %@"),
                workspace
            )
        }
        return summary
    }

    private static func formatDiagnosticBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = .useAll
        return formatter.string(fromByteCount: max(0, bytes))
    }
}
