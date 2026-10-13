import Foundation

/// Why a process that shares a surface's TTY device was, or was not, attributed to it.
///
/// A terminal's TTY is not proof of ownership. A process reparented to launchd keeps the
/// controlling TTY of the terminal it was launched from, so the TTY population always has
/// to be split into processes bree can prove it owns and processes that merely collide on
/// the device. See https://github.com/ecyx00/bree/issues/11004.
enum BreeTopTTYOwnershipReason: String, Sendable, CaseIterable {
    /// The process carries an explicit `BREE_*` scope naming this surface. Strongest
    /// evidence, and the one that survives reparenting: hook monitors and browser roots
    /// are intentionally launchd-parented but stay attributed through it.
    case breeProcessScope = "bree-process-scope"

    /// The process was already proven through the surface's bree-scoped process tree.
    case surfaceProcessTree = "surface-process-tree"

    /// The process was launched onto this TTY by a bree-owned process off the TTY, which
    /// is how the shell bree forks for a surface looks.
    case ttySessionRoot = "tty-session-root"

    /// The process descends from a proven owner on this TTY.
    case ttyDescendant = "tty-descendant"

    /// The process belongs to a process group whose leader is a proven owner, which is how
    /// a backgrounded job of the surface's shell looks after its parent goes away.
    case ttyProcessGroup = "tty-process-group"

    /// The process only shares the TTY device. No descendant, process-group, or bree-scope
    /// evidence links it to the surface, so its memory is not bree's to claim.
    case ttyCollision = "tty-collision"
}

/// The minimum a process has to expose for TTY ownership to be decidable.
struct BreeTopTTYOwnershipProcess: Sendable, Equatable {
    /// The process identifier.
    let pid: Int
    /// The parent process identifier. `1` means launchd, i.e. the process was reparented
    /// and its parent link no longer says who started it.
    let parentPID: Int
    /// The process group identifier, when the snapshot could read one.
    let processGroupID: Int?
    /// The bree surface named by the process's `BREE_*` environment scope, when present.
    let breeSurfaceID: UUID?

    /// Creates the process facts used to decide TTY ownership.
    init(pid: Int, parentPID: Int, processGroupID: Int?, breeSurfaceID: UUID?) {
        self.pid = pid
        self.parentPID = parentPID
        self.processGroupID = processGroupID
        self.breeSurfaceID = breeSurfaceID
    }
}

/// The result of splitting one TTY's process population by ownership evidence.
struct BreeTopTTYOwnership: Sendable {
    /// Processes bree can prove belong to the surface. Safe to use as attribution roots.
    var provenPIDs: Set<Int> = []

    /// Processes that share the TTY device with no ownership evidence. Reported separately
    /// so a detached REPL or dev server is visible without being charged to the surface.
    var unattributedPIDs: Set<Int> = []

    /// Per-PID reason, for diagnostics and the Task Manager.
    var reasonByPID: [Int: BreeTopTTYOwnershipReason] = [:]

    /// String-keyed reasons for the JSON payloads, which cannot carry `Int` keys.
    func reasonPayload() -> [String: String] {
        var payload: [String: String] = [:]
        payload.reserveCapacity(reasonByPID.count)
        for (pid, reason) in reasonByPID {
            payload[String(pid)] = reason.rawValue
        }
        return payload
    }
}

/// Decides which processes on a surface's TTY the surface actually owns.
///
/// Attribution fails closed: a PID is charged to the surface only when the snapshot
/// carries positive evidence for it, so an unrelated detached workload that merely
/// inherited the TTY is reported rather than summed into bree's memory.
struct BreeTopTTYOwnershipResolver {
    /// PIDs known to belong to bree — the window's app processes and their descendants.
    /// A process launched onto the TTY by one of these is a surface root; without this
    /// evidence an off-TTY parent proves nothing.
    private let breeOwnedPIDs: Set<Int>

    /// Creates a resolver that trusts `breeOwnedPIDs` as launch evidence.
    init(breeOwnedPIDs: Set<Int>) {
        self.breeOwnedPIDs = breeOwnedPIDs
    }

    /// Splits `candidates` into proven owners of `surfaceID` and same-TTY collisions.
    ///
    /// Runs in time linear in the candidate count: parent and process-group indexes are
    /// built once, then each newly proven PID is visited exactly once from a work queue.
    ///
    /// - Parameters:
    ///   - candidates: every PID sharing the surface's TTY device.
    ///   - processes: process facts for those PIDs. A PID missing here cannot be proven.
    ///   - surfaceID: the surface being annotated, when it has an identifier.
    ///   - provenPIDs: PIDs already proven by a stronger path, such as the expanded
    ///     bree-scoped process tree for this surface.
    /// - Returns: the proven set, the unattributed set, and the reason for each PID.
    func resolve(
        candidates: Set<Int>,
        processes: [Int: BreeTopTTYOwnershipProcess],
        surfaceID: UUID?,
        provenPIDs: Set<Int> = []
    ) -> BreeTopTTYOwnership {
        var ownership = BreeTopTTYOwnership()
        let livePIDs = candidates.filter { $0 > 0 }
        guard !livePIDs.isEmpty else { return ownership }

        // Built once so propagation never rescans the candidate set.
        var childrenByParentPID: [Int: [Int]] = [:]
        var membersByProcessGroupID: [Int: [Int]] = [:]
        for pid in livePIDs {
            guard let process = processes[pid] else { continue }
            if process.parentPID > 1 {
                childrenByParentPID[process.parentPID, default: []].append(pid)
            }
            if let processGroupID = process.processGroupID, processGroupID != pid {
                membersByProcessGroupID[processGroupID, default: []].append(pid)
            }
        }

        var proven: Set<Int> = []
        var queue: [Int] = []

        func prove(_ pid: Int, _ reason: BreeTopTTYOwnershipReason) {
            guard proven.insert(pid).inserted else { return }
            ownership.reasonByPID[pid] = reason
            queue.append(pid)
        }

        for pid in livePIDs {
            guard let process = processes[pid] else { continue }

            if let surfaceID, process.breeSurfaceID == surfaceID {
                prove(pid, .breeProcessScope)
                continue
            }
            if provenPIDs.contains(pid) {
                prove(pid, .surfaceProcessTree)
                continue
            }
            // An off-TTY parent only proves ownership when that parent is bree's. PID 1 is
            // launchd, and an arbitrary third-party parent says nothing about this surface.
            if process.parentPID > 1,
               !livePIDs.contains(process.parentPID),
               breeOwnedPIDs.contains(process.parentPID) {
                prove(pid, .ttySessionRoot)
            }
        }

        // Ownership is transitive: a child of a proven owner is proven, and so is a member
        // of a process group whose leader is proven. Each proven PID is expanded once.
        while let pid = queue.popLast() {
            for child in childrenByParentPID[pid] ?? [] {
                prove(child, .ttyDescendant)
            }
            for member in membersByProcessGroupID[pid] ?? [] {
                prove(member, .ttyProcessGroup)
            }
        }

        ownership.provenPIDs = proven
        for pid in livePIDs where !proven.contains(pid) {
            ownership.unattributedPIDs.insert(pid)
            ownership.reasonByPID[pid] = .ttyCollision
        }
        return ownership
    }
}
