import BreeFoundation
import Foundation

extension BreeTopProcessSnapshot {
    /// Builds the app-scoped process census authority at the composition root.
    static func makeProcessSnapshotService() -> ProcessSnapshotService<BreeTopProcessCapture, BreeTopProcessFields> {
        ProcessSnapshotService(
            capture: { try BreeTopProcessSampler().capture() },
            enrich: { try BreeTopProcessSampler().enrich($0, fields: $1) }
        )
    }

    /// Enumerates after this request. An older diagnostic census cannot authorize
    /// lifecycle decisions merely because its enrichment finished more recently.
    static func capture(
        includeProcessDetails: Bool = false,
        includeBREEScope: Bool = true,
        includeResources: Bool = true,
        service: ProcessSnapshotService<BreeTopProcessCapture, BreeTopProcessFields>? = nil
    ) async -> BreeTopProcessSnapshot {
        await capture(
            fields: BreeTopProcessFields(details: includeProcessDetails, scope: includeBREEScope, resources: includeResources),
            freshness: .afterRequest, service: service ?? defaultProcessSnapshotService()
        )
    }

    /// Permits diagnostic reuse only within the explicit age bound from census start.
    static func captureCached(
        includeProcessDetails: Bool = false,
        includeBREEScope: Bool = true,
        includeResources: Bool = true,
        maximumAge: TimeInterval,
        service: ProcessSnapshotService<BreeTopProcessCapture, BreeTopProcessFields>? = nil
    ) async -> BreeTopProcessSnapshot {
        await capture(
            fields: BreeTopProcessFields(details: includeProcessDetails, scope: includeBREEScope, resources: includeResources),
            // While terminals stream output, a diagnostic census a few
            // seconds older is as good as a new one and costs a full process walk.
            freshness: .maximumAge(.seconds(max(0, maximumAge) * (TerminalOutputStreamingMonitor.shared.isStreaming() ? 4 : 1))), service: service ?? defaultProcessSnapshotService()
        )
    }

    private static func capture(
        fields: BreeTopProcessFields, freshness: ProcessSnapshotFreshness,
        service: ProcessSnapshotService<BreeTopProcessCapture, BreeTopProcessFields>
    ) async -> BreeTopProcessSnapshot {
        do {
            return try await service.snapshot(fields: fields, freshness: freshness).snapshot
        } catch {
            // Expiry, cancellation and admission failure are unavailable evidence,
            // never a complete empty machine. Safety callers must fail closed.
            return BreeTopProcessSnapshot(
                processes: [], sampledAt: Date(), includesProcessDetails: fields.contains(.details),
                includesBREEScope: fields.contains(.scope), includesResources: fields.contains(.resources),
                enumerationIsComplete: false,
                captureIsAvailable: false
            )
        }
    }

    static func allProcesses(includeProcessDetails: Bool, includeBREEScope: Bool) async -> [BreeTopProcessInfo] {
        let snapshot = await capture(includeProcessDetails: includeProcessDetails, includeBREEScope: includeBREEScope, includeResources: false)
        return Array(snapshot.processesByPID.values)
    }

    private static func defaultProcessSnapshotService() -> ProcessSnapshotService<BreeTopProcessCapture, BreeTopProcessFields> {
        AppDelegate.shared?.processSnapshotService ?? makeProcessSnapshotService()
    }
}
