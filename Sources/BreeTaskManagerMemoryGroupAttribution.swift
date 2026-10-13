import Foundation

/// Describes whether a memory group has one common owner, several owners, or incomplete attribution.
enum BreeTaskManagerMemoryGroupAttribution: Sendable {
    case common(BreeTaskManagerMemoryAttribution)
    case multiple(workspaceCount: Int, ownerCount: Int)
    case partial(attributedProcessCount: Int, unattributedProcessCount: Int)
    case unattributed

    init?(_ payload: [String: Any]) {
        guard let kind = BreeTaskManagerMemoryDiagnostic.string(payload["kind"]) else {
            return nil
        }
        switch kind {
        case "common":
            guard let owner = BreeTaskManagerMemoryAttribution(payload["owner"] as? [String: Any]) else {
                return nil
            }
            self = .common(owner)
        case "multiple":
            self = .multiple(
                workspaceCount: BreeTaskManagerMemoryDiagnostic.int(payload["workspace_count"]) ?? 0,
                ownerCount: BreeTaskManagerMemoryDiagnostic.int(payload["owner_count"]) ?? 0
            )
        case "partial":
            self = .partial(
                attributedProcessCount: BreeTaskManagerMemoryDiagnostic.int(
                    payload["attributed_process_count"]
                ) ?? 0,
                unattributedProcessCount: BreeTaskManagerMemoryDiagnostic.int(
                    payload["unattributed_process_count"]
                ) ?? 0
            )
        case "unattributed":
            self = .unattributed
        default:
            return nil
        }
    }

    var commonOwner: BreeTaskManagerMemoryAttribution? {
        guard case .common(let owner) = self else { return nil }
        return owner
    }

    var localizedDescription: String {
        switch self {
        case .common(let owner):
            owner.localizedDescription
        case .multiple(let workspaceCount, _):
            if workspaceCount > 1 {
                String.localizedStringWithFormat(
                    String(localized: "memory.attribution.multipleWorkspaces", defaultValue: "%lld workspaces"),
                    workspaceCount
                )
            } else {
                String(localized: "memory.attribution.multipleOwners", defaultValue: "multiple owners")
            }
        case .partial:
            String(localized: "memory.attribution.partial", defaultValue: "partially attributed")
        case .unattributed:
            String(localized: "taskManager.memory.unattributed", defaultValue: "Unattributed")
        }
    }
}
