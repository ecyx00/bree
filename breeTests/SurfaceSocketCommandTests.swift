import BreeCloud
import AppKit
import BreeSurfaceCatalogModel
import Foundation
import Testing
#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

/// The socket face of the surface catalog, driven the way the CLI drives it: JSON-RPC
/// lines into `handleSocketLine` from a socket-worker thread, against a fake cloud
/// provider registered on the shared catalog. These pin behavior — what
/// `surface.catalog` / `surface.project` / `surface.new_terminal` / `vm.workspace_*` /
/// `vm.terminal_*` answer and what they ask the provider to do — not source shape.
@MainActor
@Suite(.serialized)
struct SurfaceSocketCommandTests {
    @Test func emptyWorkspaceHasARetryableSocketCode() async throws {
        let response = await Task.detached {
            TerminalController.shared.v2VmCall(id: "empty-workspace", timeoutSeconds: 5) {
                throw SurfaceCatalogError.nothingToOpen("workspace ws_pending")
            }
        }.value
        let object = try #require(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        let error = try Self.error(object)
        #expect(error["code"] as? String == "not_ready")
    }

    /// A cloud provider whose daemon is a notebook: every verb records what it was asked.
    private final class FakeCloudProvider: SurfaceProvider {
        let machine: SurfaceMachineID
        var info: SurfaceMachineInfo
        unowned let catalog: SurfaceCatalog
        var materialized: [(resource: SurfaceResourceID, destination: SurfaceDestination, focus: Bool)] = []
        var createdTerminals: [(command: [String]?, cwd: String?, name: String?, remoteWorkspaceID: String?)] = []
        var mutations: [String] = []
        var refreshes = 0

        init(machine: SurfaceMachineID, catalog: SurfaceCatalog, workspaces: [SurfaceRemoteWorkspace]) {
            self.machine = machine
            self.catalog = catalog
            info = SurfaceMachineInfo(
                id: machine, name: machine.rawValue, status: "running", image: "bree-devbox", hasDesktop: false,
                memoryMb: nil, diskMb: nil, linkState: .connected, linkError: nil,
                cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil, remoteWorkspaces: workspaces
            )
        }

        func refresh() async { refreshes += 1 }

        func materialize(_ resource: SurfaceResource, at destination: SurfaceDestination, focus: Bool) async throws -> SurfaceProjection {
            materialized.append((resource.id, destination, focus))
            return SurfaceProjection(resource: resource.id, workspaceID: destination.workspaceID, panelID: UUID())
        }

        func createTerminal(command: [String]?, cwd: String?, name: String?, remoteWorkspaceID: String?) async throws -> SurfaceResource {
            createdTerminals.append((command, cwd, name, remoteWorkspaceID))
            let workspace = (info.remoteWorkspaces ?? []).first { $0.id == remoteWorkspaceID } ?? info.remoteWorkspaces?.first
            let resource = SurfaceResource(
                id: SurfaceResourceID(machine: machine, kind: .terminal, key: "term_new_\(createdTerminals.count)"),
                title: name ?? "", detail: cwd, lifecycle: .launching, agent: nil,
                remoteWorkspace: workspace, port: nil, url: nil
            )
            // Like the real provider: the terminal exists in the catalog before it is projected.
            catalog.upsert(resource)
            return resource
        }

        func projectionDidEnd(_ projection: SurfaceProjection) {}

        func closeTerminal(_ id: SurfaceResourceID) async throws {
            mutations.append("terminal close \(id.key)")
            catalog.remove(id)
        }

        func createRemoteWorkspace(name: String?) async throws -> SurfaceRemoteWorkspace {
            mutations.append("workspace create \(name ?? "-")")
            let workspace = SurfaceRemoteWorkspace(id: "ws_created", name: name ?? "main", index: info.remoteWorkspaces?.count ?? 0, focused: false)
            info.remoteWorkspaces = (info.remoteWorkspaces ?? []) + [workspace]
            catalog.updateMachine(info, from: self)
            return workspace
        }

        func closeRemoteWorkspace(id: String) async throws {
            mutations.append("workspace close \(id)")
        }

        func renameRemoteWorkspace(id: String, name: String) async throws {
            mutations.append("workspace rename \(id) \(name)")
        }

        func renameRemoteTab(id: String, name: String) async throws {
            mutations.append("tab rename \(id) \(name)")
        }

        func renameTerminal(_ id: SurfaceResourceID, name: String) async throws {
            mutations.append("terminal rename \(id.key) \(name)")
        }
    }

    /// One registered fake machine with two workspaces: `ws_a` holds `term_a1` and
    /// `term_a2` (plus a daemon browser); `ws_b` holds `term_b`; `ws_empty` holds nothing.
    private struct Fixture {
        let machineID: String
        let machine: SurfaceMachineID
        let provider: FakeCloudProvider
        let manager: TabManager
        let workspaceID: UUID
        static let wsA = SurfaceRemoteWorkspace(id: "ws_a", name: "alpha", index: 0, focused: true)
        static let wsB = SurfaceRemoteWorkspace(id: "ws_b", name: "beta", index: 1, focused: false)
        static let wsEmpty = SurfaceRemoteWorkspace(id: "ws_empty", name: "empty", index: 2, focused: false)

        var termA1: SurfaceResourceID { SurfaceResourceID(machine: machine, kind: .terminal, key: "term_a1") }
        var termA2: SurfaceResourceID { SurfaceResourceID(machine: machine, kind: .terminal, key: "term_a2") }
        var termB: SurfaceResourceID { SurfaceResourceID(machine: machine, kind: .terminal, key: "term_b") }
        var browserA: SurfaceResourceID { SurfaceResourceID(machine: machine, kind: .browser, key: "browser_1") }

        @MainActor
        init(manager: TabManager, device: Bool = false) {
            // Locals first: a nested helper must not capture `self` before every stored
            // property is initialized.
            let machineID = "sock-" + UUID().uuidString.lowercased().prefix(8)
            let machine = device ? SurfaceMachineID.device(SurfaceDeviceInstanceID(deviceID: UUID().uuidString, tag: "default")) : .cloud(machineID)
            let catalog = SurfaceCatalog.shared
            let provider = FakeCloudProvider(machine: machine, catalog: catalog, workspaces: [Self.wsA, Self.wsB, Self.wsEmpty])
            catalog.register(provider)
            let terminal: (String, SurfaceRemoteWorkspace) -> SurfaceResource = { key, workspace in
                var resource = SurfaceResource(
                    id: SurfaceResourceID(machine: machine, kind: .terminal, key: key), title: key, detail: "/root",
                    lifecycle: .running, agent: nil, remoteWorkspace: workspace, port: nil, url: nil
                )
                resource.remoteViews = [SurfaceRemoteView(tabID: "tab_\(key)", workspace: workspace)]
                return resource
            }
            var browser = SurfaceResource(
                id: SurfaceResourceID(machine: machine, kind: .browser, key: "browser_1"), title: "docs", detail: "http://localhost:3000",
                lifecycle: .running, agent: nil, remoteWorkspace: Self.wsA, port: 3000, url: "http://localhost:3000"
            )
            browser.remoteViews = [SurfaceRemoteView(tabID: "tab_browser_1", workspace: Self.wsA)]
            catalog.replaceResources(
                [terminal("term_a1", Self.wsA), terminal("term_a2", Self.wsA), terminal("term_b", Self.wsB), browser],
                on: machine,
                info: provider.info
            )
            TerminalController.shared.setActiveTabManager(manager)
            self.machineID = machine.rawValue
            self.machine = machine
            self.provider = provider
            self.manager = manager
            self.workspaceID = manager.selectedWorkspace!.id
        }

        /// The pane belongs to this windowless fixture, so requests also name
        /// its workspace instead of asking the live-window router to find it.
        @MainActor
        var livePaneID: String? {
            // Straight from the workspace: the test TabManager is the controller's active
            // manager but is not registered with the app's window list.
            guard let workspace = manager.selectedWorkspace, let panel = workspace.focusedPanelId else { return nil }
            return workspace.paneId(forPanelId: panel)?.id.uuidString
        }

        @MainActor
        func tearDown() {
            TerminalController.shared.setActiveTabManager(nil)
            SurfaceCatalog.shared.unregister(machine: machine)
            manager.tabs.forEach { $0.teardownAllPanels() }

        }
    }

    private static func withFixture(device: Bool = false, _ body: (Fixture) async throws -> Void) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
            let flag = BreeFeatureFlags.cloudMachinesFlag
            let previousOverride = BreeFeatureFlags.shared.overrideValue(for: flag)
            let betaKey = RightSidebarBetaFeatureSettings.cloudMachinesEnabledKey
            let previousBeta = UserDefaults.standard.object(forKey: betaKey)
            let app = try VaultPaneAppFixture()
            // `vm.workspace_new` admits its optimistic local workspace through the
            // active main window before it asks the provider for anything; a
            // context without a window is pruned and the call is cancelled. Bind
            // a bare window the way the shortcut tests do.
            let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
            window.identifier = NSUserInterfaceItemIdentifier("bree.main.\(app.windowID.uuidString)")
            app.appDelegate.mainWindowContexts.values.first { $0.windowId == app.windowID }?.window = window
            defer { withExtendedLifetime(window) {} }
            defer {
                app.tearDown()
                TerminalController.shared.setActiveTabManager(previousManager)
                UserDefaults.standard.set(previousBeta, forKey: betaKey)
                BreeFeatureFlags.shared.setOverride(previousOverride, for: flag)
            }
            UserDefaults.standard.set(true, forKey: betaKey)
            BreeFeatureFlags.shared.setOverride(true, for: flag)
            let fixture = Fixture(manager: app.manager, device: device)
            defer { fixture.tearDown() }
            try await body(fixture)
        }
    }

    // MARK: - transport

    /// Sends one request the way a socket client does: off the main thread (the
    /// surface/vm verbs run on the socket-worker lane and park it while the catalog
    /// works on the main actor).
    private nonisolated static func call(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": UUID().uuidString, "method": method, "params": params]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let response = TerminalController.shared.handleSocketLine(line)
                do {
                    let object = try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any]
                    continuation.resume(returning: object ?? [:])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func ok(_ response: [String: Any]) throws -> [String: Any] {
        #expect(response["ok"] as? Bool == true, "expected success, got \(response)")
        return try #require(response["result"] as? [String: Any])
    }

    private static func error(_ response: [String: Any]) throws -> [String: Any] {
        #expect(response["ok"] as? Bool == false, "expected an error, got \(response)")
        return try #require(response["error"] as? [String: Any])
    }

    private static func resourceIDs(_ result: [String: Any]) -> Set<String> {
        Set(((result["resources"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String })
    }

    // MARK: - surface.catalog / vm.tree

    // MARK: - surface.project

    @Test func projectReusesFocusesAndHonorsPlacementFlags() async throws {
        try await Self.withFixture { fixture in
            let resource = fixture.termA1.rawValue

            let first = try Self.ok(try await Self.call("surface.project", ["resource": resource]))
            #expect(first["reused"] as? Bool == false)
            #expect(first["workspace_id"] as? String == fixture.workspaceID.uuidString, "no target → the selected workspace")
            #expect(fixture.provider.materialized.count == 1)
            #expect(fixture.provider.materialized[0].destination == .workspace(id: fixture.workspaceID, placement: .split))
            // A socket client that does not ask for focus opens in the background: an agent
            // must not pull the person away from what they are typing in.
            #expect(fixture.provider.materialized[0].focus == false)

            // The catalog reuses the pane already showing the resource…
            let again = try Self.ok(try await Self.call("surface.project", ["resource": resource]))
            #expect(again["reused"] as? Bool == true)
            #expect(again["surface_id"] as? String == first["surface_id"] as? String)
            #expect(fixture.provider.materialized.count == 1)

            // …unless `reuse: false` (`--new`): a second pane, at the pane edge the caller named
            // (a LIVE pane: the workspace's own focused pane).
            let pane = try #require(fixture.livePaneID)
            let split = try Self.ok(try await Self.call("surface.project", [
                "resource": resource, "reuse": false, "workspace_id": fixture.workspaceID.uuidString,
                "pane_id": pane, "direction": "left", "focus": false,
            ]))
            #expect(split["reused"] as? Bool == false)
            #expect(fixture.provider.materialized.count == 2)
            #expect(fixture.provider.materialized[1].destination == .split(workspaceID: fixture.workspaceID, paneID: pane, direction: .left))
            #expect(fixture.provider.materialized[1].focus == false)

            // `placement: tab` on a pane becomes a tab destination.
            _ = try Self.ok(try await Self.call("surface.project", [
                "resource": resource, "reuse": false, "workspace_id": fixture.workspaceID.uuidString,
                "pane_id": pane, "placement": "tab",
            ]))
            #expect(fixture.provider.materialized.last?.destination == .tab(workspaceID: fixture.workspaceID, paneID: pane, index: nil))
            #expect(fixture.provider.materialized.last?.focus == false)

            // An explicit `focus: true` (an interactive `bree surface open`, or `--focus`) is honored.
            _ = try Self.ok(try await Self.call("surface.project", [
                "resource": resource, "reuse": false, "workspace_id": fixture.workspaceID.uuidString, "focus": true,
            ]))
            #expect(fixture.provider.materialized.last?.focus == true)

            let projections = try Self.ok(try await Self.call("surface.catalog", ["machine": fixture.machineID]))["projections"] as? [[String: Any]]
            #expect(projections?.filter { ($0["resource"] as? String) == resource }.count == 4)
        }
    }

    @Test func projectRejectsUnknownSurfacesAndUnresolvableTargets() async throws {
        try await Self.withFixture { fixture in

            let unknown = try Self.error(try await Self.call("surface.project", ["resource": "\(fixture.machineID)/terminal/term_ghost"]))
            #expect((unknown["message"] as? String)?.contains("Unknown surface") == true)

            // An explicit workspace that resolves to nothing is an error, never a silent
            // fall-through to the selected workspace.
            let bogus = try Self.error(try await Self.call("surface.project", ["resource": fixture.termA1.rawValue, "workspace_id": "workspace:999999"]))
            #expect(bogus["code"] as? String == "invalid_params")
            #expect((bogus["message"] as? String)?.contains("workspace:999999") == true)
            let bogusPane = try Self.error(try await Self.call("surface.project", ["resource": fixture.termA1.rawValue, "pane_id": "pane:999999"]))
            #expect(bogusPane["code"] as? String == "invalid_params")
            // Well-formed but dead ids are just as unresolvable: a closed pane's UUID, a
            // workspace UUID nobody has, a surface UUID that is not a panel.
            for (key, value) in [("pane_id", UUID().uuidString), ("workspace_id", UUID().uuidString), ("surface_id", UUID().uuidString)] {
                let dead = try Self.error(try await Self.call("surface.project", ["resource": fixture.termA1.rawValue, key: value]))
                #expect(dead["code"] as? String == "invalid_params", "\(key) \(value) must not fall back to the selected workspace")
            }
            #expect(fixture.provider.materialized.isEmpty, "nothing opened anywhere")

            let malformed = try Self.error(try await Self.call("surface.project", ["resource": "not-a-resource"]))
            #expect(malformed["code"] as? String == "invalid_params")
        }
    }

    @Test func projectResolvesAnExplicitSurfaceInAnotherWindow() async throws {
        try await Self.withFixture { fixture in
            let app = try #require(AppDelegate.shared)
            // This test exercises ownership lookup, not window rendering.
            // Keep the second window context deterministic and avoid leaving
            // SwiftUI render/teardown work running into the next socket test.
            let manager = TabManager(autoWelcomeIfNeeded: false)
            let windowID = app.registerMainWindowContextForTesting(tabManager: manager)
            defer {
                app.unregisterMainWindowContextForTesting(windowId: windowID)
                manager.tabs.forEach { $0.teardownAllPanels() }
            }
            let workspace = try #require(manager.selectedWorkspace)
            let surfaceID = try #require(workspace.focusedPanelId)
            let paneID = try #require(workspace.paneId(forPanelId: surfaceID))
            TerminalController.shared.setActiveTabManager(fixture.manager)

            let result = try Self.ok(try await Self.call("surface.project", [
                "resource": fixture.termA1.rawValue,
                "workspace_id": workspace.id.uuidString,
                "surface_id": surfaceID.uuidString,
                "direction": "left",
                "focus": false,
            ]))

            #expect(result["workspace_id"] as? String == workspace.id.uuidString)
            #expect(fixture.provider.materialized.count == 1)
            #expect(fixture.provider.materialized[0].destination == .split(
                workspaceID: workspace.id, paneID: paneID.id.uuidString, direction: .left
            ))
            #expect(fixture.provider.materialized[0].focus == false)
        }
    }

    // MARK: - surface.new_terminal / vm.terminal_new

    // MARK: - background opens

    @Test func backgroundOpenMarksThePaneUnreadUnlessThePersonIsLookingAtIt() async throws {
        try await Self.withFixture { fixture in
            let manager = fixture.manager
            let selected = try #require(manager.selectedWorkspace)
            let background = try #require(manager.addWorkspaceIfActive(select: false, autoWelcomeIfNeeded: false))
            defer { manager.closeWorkspace(background, recordHistory: false) }
            #expect(manager.selectedTabId == selected.id)
            let landed = try #require(background.focusedPanelId)
            #expect(!background.panelIsUnread(landed))

            SurfacePaneFactory.markOpenedInBackground(panelID: landed, in: background.id)
            #expect(background.panelIsUnread(landed), "something landed where the person is not looking")

            let onScreen = try #require(selected.focusedPanelId)
            SurfacePaneFactory.markOpenedInBackground(panelID: onScreen, in: selected.id)
            #expect(!selected.panelIsUnread(onScreen), "the pane the person is looking at is not news")
        }
    }

}
