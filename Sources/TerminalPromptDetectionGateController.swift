import CmuxTerminal
import CmuxTerminalCore
import CmuxWorkspaces
import Foundation
import os

/// Owns each terminal's ``PromptDetectionGate``.
///
/// The PTY read thread only loads the gate's atomic epoch. This controller, on
/// the main actor, turns the gate on while the surface's foreground command is
/// an agent REPL with prompt detection (`ollama run`) and off at every other
/// time, so output nobody is listening for costs nothing in Swift. The process
/// lookup runs on a utility task, never on the read thread.
@MainActor
final class TerminalPromptDetectionGateController {
    static let shared = TerminalPromptDetectionGateController()

    private nonisolated let gates = OSAllocatedUnfairLock(initialState: [UUID: PromptDetectionGate]())
    private var probeTasks: [UUID: Task<Void, Never>] = [:]

    /// The gate for a surface, created on first use. It starts on, so a
    /// shell without integration that never reports its state still works.
    nonisolated func gate(for surfaceID: UUID) -> PromptDetectionGate {
        gates.withLock { gates in
            if let existing = gates[surfaceID] { return existing }
            let created = PromptDetectionGate()
            gates[surfaceID] = created
            return created
        }
    }

    func dropSurface(_ surfaceID: UUID) {
        probeTasks.removeValue(forKey: surfaceID)?.cancel()
        gates.withLock { _ = $0.removeValue(forKey: surfaceID) }
    }

    /// Follows the shell-integration state. A prompt means no foreground
    /// agent; a running command is probed on a short, bounded ladder.
    func shellStateChanged(surface: TerminalSurface, state: PanelShellActivityState) {
        let surfaceID = surface.id
        switch state {
        case .unknown:
            return
        case .promptIdle:
            probeTasks.removeValue(forKey: surfaceID)?.cancel()
            gate(for: surfaceID).disable()
            logGate(surfaceID, "prompt-idle")
        case .commandRunning:
            probeTasks.removeValue(forKey: surfaceID)?.cancel()
            // On from the start: the REPL's first prompt can appear before
            // any probe could name the process. The ladder turns the gate
            // off again once the command is shown not to be an agent.
            let gate = gate(for: surfaceID)
            gate.enable()
            logGate(surfaceID, "command-start")
            probeTasks[surfaceID] = Task { @MainActor [weak surface] in
                var elapsed = Duration.zero
                for (step, delay) in PromptDetectionProbeSchedule.delays.enumerated() {
                    do {
                        try await Task.sleep(for: delay - elapsed)
                    } catch {
                        return
                    }
                    elapsed = delay
                    var isAgent = false
                    var probedPID = 0
                    if let surface, let pid = surface.foregroundProcessID() {
                        probedPID = pid
                        isAgent = await Task.detached(priority: .utility) {
                            CmuxTopProcessSnapshot.promptAgentDefinition(foregroundPID: pid) != nil
                        }.value
                    }
                    logGate(surfaceID, "probe step=\(step) pid=\(probedPID) agent=\(isAgent)")
                    guard !Task.isCancelled else { return }
                    if isAgent {
                        gate.enable()
                        logGate(surfaceID, "agent-found step=\(step)")
                        return
                    }
                    if step == PromptDetectionProbeSchedule.disableAfterStep {
                        gate.disable()
                        logGate(surfaceID, "no-agent step=\(step)")
                    }
                }
            }
        }
    }

    private func logGate(_ surfaceID: UUID, _ event: String) {
        #if DEBUG
        cmuxDebugLog("promptGate surface=\(surfaceID.uuidString.prefix(5)) \(event)")
        #endif
    }
}
