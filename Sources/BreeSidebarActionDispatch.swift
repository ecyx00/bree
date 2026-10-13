import AppKit
import BreeSwiftRender
import BreeSwiftRenderUI
import Foundation

/// Serial lane for in-process `bree(...)` sidebar actions. Worker-lane methods
/// (browser JS, waits) must run off the main actor: on the main actor they
/// starve SwiftUI and deadlock on a not-yet-mounted webview, which is exactly
/// why they were moved off the main-actor dispatch path. Running the whole
/// action on one serial queue keeps every command in its authored order, so a
/// later command can't finish before an earlier browser navigate/click/wait.
private let breeSidebarWorkerQueue = DispatchQueue(label: "com.bree.sidebar-action-worker")

/// Select-burst coalescing lives in ``SidebarSelectCoalescer``
/// (BreeSwiftRenderUI), where its FIFO/newest-wins semantics are unit-tested.
private let sidebarSelectCoalescer = SidebarSelectCoalescer()

// The custom-sidebar rendering, interpreter, JSON DSL, resizable split, and
// the file-watching model now live in the `BreeSwiftRender` (logic) and
// `BreeSwiftRenderUI` (SwiftUI) packages. The app target keeps only the
// bree-coupled action dispatch, the one piece that must reach
// `TerminalController`, and injects it into the package's view from
// `ContentView`.

/// Builds the action sink that runs interpreted sidebar buttons against the
/// live bree command dispatcher.
///
/// `bree(...)` commands run in-process through
/// `TerminalController.handleSocketLine(_:)` (the same worker-aware surface the
/// socket CLI uses); `log` is a debug-only no-op for now.
@MainActor
func makeBreeSidebarActionDispatch() -> SidebarActionDispatch {
    SidebarActionDispatch { action in
        // Capture the controller on the main actor, then run the whole command
        // sequence on the serial worker queue so the commands keep their authored
        // order. handleSocketLine runs worker-lane methods (browser JS, waits) on
        // this thread and hops main-actor methods back to the main actor itself,
        // so nothing here blocks SwiftUI and ordering is preserved end to end.
        let controller = TerminalController.shared
        let commands = action.commands
        let selectGeneration = sidebarSelectCoalescer.generation(for: commands)
        breeSidebarWorkerQueue.async {
            // A newer select is already queued behind this one: skip the heavy
            // switch, the burst's final click defines the end state.
            if let selectGeneration, !sidebarSelectCoalescer.isCurrent(selectGeneration) {
                return
            }
            for command in commands {
                switch command {
                case let .bree(method, params):
                    var payload: [String: Any] = ["method": method, "id": UUID().uuidString]
                    if !params.isEmpty {
                        // Params arrive as strings; coerce integer-looking values
                        // (e.g. a reorder `index`) to numbers so typed v2 params
                        // like v2Int decode them.
                        var typed: [String: Any] = [:]
                        for (key, value) in params {
                            if let intValue = Int(value) {
                                typed[key] = intValue
                            } else if value.hasPrefix("["),
                                      let data = value.data(using: .utf8),
                                      let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any] {
                                // Array-typed v2 params (e.g. child_workspace_ids)
                                // travel as JSON strings through the string-only
                                // action pipe; inflate them here.
                                typed[key] = array
                            } else {
                                typed[key] = value
                            }
                        }
                        payload["params"] = typed
                    }
                    guard let data = try? JSONSerialization.data(withJSONObject: payload),
                          let line = String(data: data, encoding: .utf8) else { continue }
                    _ = controller.handleSocketLine(line)
                case let .openURL(urlString):
                    // NSWorkspace.open is main-only; run it synchronously to keep the
                    // command's position in the sequence.
                    if let url = URL(string: urlString) {
                        DispatchQueue.main.sync { _ = NSWorkspace.shared.open(url) }
                    }
                case .log:
                    break
                }
            }
        }
    }
}
