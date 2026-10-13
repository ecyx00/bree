import Foundation

/// Decodes one command-name aggregate from the memory diagnostic payload.
struct BreeTaskManagerMemoryGroup: Sendable {
    let id: String
    let name: String
    let rssBytes: Int64
    let processCount: Int
    let processIds: [Int]
    let attribution: BreeTaskManagerMemoryGroupAttribution

    init?(_ payload: [String: Any]) {
        guard let name = BreeTaskManagerMemoryDiagnostic.string(payload["name"]) else {
            return nil
        }
        let processCount = BreeTaskManagerMemoryDiagnostic.int(payload["process_count"]) ?? 0
        guard processCount > 0 else { return nil }
        self.id = BreeTaskManagerMemoryDiagnostic.string(payload["id"]) ?? name.lowercased()
        self.name = name
        self.rssBytes = BreeTaskManagerMemoryDiagnostic.int64(payload["rss_bytes"])
        self.processCount = processCount
        self.processIds = BreeTaskManagerMemoryDiagnostic.intArray(payload["pids"])
        let topAttribution = BreeTaskManagerMemoryAttribution(payload["top_attribution"] as? [String: Any])
        self.attribution = BreeTaskManagerMemoryGroupAttribution(
            payload["group_attribution"] as? [String: Any] ?? [:]
        )
            ?? topAttribution.map(BreeTaskManagerMemoryGroupAttribution.common)
            ?? .unattributed
    }
}
