import BreeControlSocket
import BreeSettings
import BreeSurfaceCatalogModel
import Foundation

// The socket face of the surface catalog: `surface.catalog`, `surface.project`,
// and nothing else. Every entrypoint (sidebar, CLI, agents) opens a surface through
// `SurfaceCatalog.project`, so "is it open?" and "where does it land?" have one answer.
//
// Lane (ControlCommandExecutionPolicy): socket worker. These await main-actor catalog work
// that can sit on the network (a remote provider materializing a pane), so they must never
// hold the main actor; `v2VmCall` parks the worker while the catalog runs on the main actor.
// Focus policy: `focus` defaults to false for every open, so an agent or script never
// pulls the person away from what they are typing in; the CLI sends `focus: true` for an
// interactive open or an explicit `--focus`. A pane opened without focus is marked
// unread (`markBackgroundOpen`). The catalog never activates the app either way.
extension TerminalController {
    nonisolated func socketWorkerSurfaceResponse(method: String, id: Any?, params: [String: Any]) -> String {
        switch method {
        case "surface.catalog":
            let machine = Self.surfaceMachineFilter(params["machine"])
            // `refresh` forces a provider pass; `ensure_linked` only connects a
            // machine that has no live graph yet (a just-created VM) and is free
            // for one that is already linked. `refresh` wins when both are sent.
            let mode: SurfaceCatalogReadMode
            if Self.surfaceBool(params["refresh"]) == true {
                mode = .forced
            } else if Self.surfaceBool(params["ensure_linked"]) == true {
                mode = .linked
            } else {
                mode = .cached
            }
            return v2VmCall(id: id, timeoutSeconds: 120) {
                let query = await Self.surfaceCatalogQuery(catalog: .shared)
                let export = await query.read(machine: machine, mode: mode)
                return Self.surfaceCatalogPayload(export, machine: machine)
            }

        case "surface.project":
            guard let raw = Self.surfaceString(params["resource"]), let resource = SurfaceResourceID(rawValue: raw) else {
                return v2Error(id: id, code: "invalid_params", message: "surface.project requires `resource` (an id from `bree surface ls --json`, e.g. vivid-newt/terminal/term_…).")
            }
            let focus = Self.surfaceBool(params["focus"]) ?? false
            let reuse = Self.surfaceBool(params["reuse"]) ?? true
            guard let workspaceID = surfaceTargetWorkspaceID(params) else {
                let requested = ["workspace_id", "pane_id", "surface_id"]
                    .compactMap { Self.surfaceString(params[$0]) }.joined(separator: ", ")
                let message = requested.isEmpty
                    ? "surface.project: no target workspace (pass `workspace_id`, or select one)."
                    : SurfaceCatalogError.destinationNotFound(requested).localizedDescription
                return v2Error(id: id, code: "invalid_params", message: message)
            }
            let destination = Self.surfaceDestination(surfaceResolvedParams(params), workspaceID: workspaceID)
            return v2VmCall(id: id, timeoutSeconds: 180) {
                let catalog = await SurfaceCatalog.shared
                let opened = try await catalog.project(
                    resource,
                    into: destination,
                    focus: focus,
                    reuseExisting: reuse
                )
                return await Self.markBackgroundOpen(Self.surfaceProjectPayload(opened.projection, reused: opened.reused), focus: focus)
            }

        default:
            return v2Error(id: id, code: "method_not_found", message: "Unknown method")
        }
    }

    // MARK: - Shared pieces

    /// The catalog's provider for `machine`; a remote machine the catalog has not seen yet
    /// (just created) gets one fleet re-read before the caller reports "no provider".
    nonisolated static func surfaceProvider(for machine: SurfaceMachineID, catalog: SurfaceCatalog) async throws -> (any SurfaceProvider)? {
        let query = await surfaceCatalogQuery(catalog: catalog)
        return await query.provider(for: machine)
    }

    @MainActor
    private static func surfaceCatalogQuery(catalog: SurfaceCatalog) -> SurfaceCatalogQueryService {
        SurfaceCatalogQueryService(catalog: catalog, projectionIdentities: { projections in
            let owners = AppDelegate.shared?.workspacesForRead(tabIds: Set(projections.map(\.workspaceID))) ?? [:]
            return SurfaceProjectionIdentity.capture(
                projections: projections,
                workspacesByID: owners
            )
        }) { machineID in
            _ = machineID
        }
    }

    /// The local workspace an open lands in: `workspace_id` (UUID or `workspace:N` ref), else
    /// the workspace of a given `pane_id`/`surface_id`, else the selected workspace. When
    /// `strictExplicit` is true, an explicit but stale/malformed pane or surface is rejected
    /// instead of silently falling through to the selected workspace (used by `vm.port_open`).
    nonisolated func surfaceTargetWorkspaceID(_ params: [String: Any], strictExplicit: Bool = true) -> UUID? {
        if strictExplicit {
            var explicitWorkspaceID: UUID?
            if v2HasNonNullParam(params, "workspace_id") {
                guard let explicit = v2UUID(params, "workspace_id") else { return nil }
                let exists = v2MainSync {
                    self.tabManager?.tabs.contains { $0.id == explicit }
                        == true
                        || AppDelegate.shared?.tabManagerFor(tabId: explicit)?.tabs.contains { $0.id == explicit }
                        == true
                }
                guard exists else { return nil }
                explicitWorkspaceID = explicit
            }
            if v2HasNonNullParam(params, "pane_id") {
                guard let paneID = v2UUID(params, "pane_id") else {
                    return nil
                }
                let locatedWorkspaceID = v2MainSync { () -> UUID? in
                    if let explicitWorkspaceID {
                        let workspace = self.tabManager?.tabs.first(where: { $0.id == explicitWorkspaceID })
                            ?? AppDelegate.shared?.tabManagerFor(tabId: explicitWorkspaceID)?.tabs.first(where: { $0.id == explicitWorkspaceID })
                        return workspace?.bonsplitController.allPaneIds.contains(where: { $0.id == paneID }) == true
                            ? explicitWorkspaceID
                            : nil
                    }
                    return self.v2LocatePane(paneID)?.workspace.id
                }
                guard let locatedWorkspaceID else { return nil }
                if let explicitWorkspaceID, explicitWorkspaceID != locatedWorkspaceID {
                    return nil
                }
                explicitWorkspaceID = locatedWorkspaceID
            }
            if v2HasNonNullParam(params, "surface_id") {
                guard let surfaceID = v2UUID(params, "surface_id") else { return nil }
                let owner = v2MainSync { () -> UUID? in
                    self.surfaceWorkspace(containing: surfaceID, preferredWorkspaceID: explicitWorkspaceID)?.id
                }
                guard let owner else { return nil }
                if let explicitWorkspaceID, explicitWorkspaceID != owner {
                    return nil
                }
                explicitWorkspaceID = owner
            }
            if let explicitWorkspaceID { return explicitWorkspaceID }
        }
        if let explicit = v2UUID(params, "workspace_id") {
            return explicit
        }
        if let paneID = v2UUID(params, "pane_id"), let located = v2MainSync({ self.v2LocatePane(paneID) }) {
            return located.workspace.id
        }
        if let surfaceID = v2UUID(params, "surface_id") {
            let owner = v2MainSync { () -> UUID? in
                self.surfaceWorkspace(containing: surfaceID)?.id
            }
            if let owner { return owner }
        }
        return v2MainSync { self.tabManager?.selectedTabId }
    }

    /// Resolves the live surface owner across windows, including projected panes.
    /// A surface UUID is never used as a workspace lookup key.
    @MainActor
    private func surfaceWorkspace(containing surfaceID: UUID, preferredWorkspaceID: UUID? = nil) -> Workspace? {
        if let preferredWorkspaceID,
           let workspace = tabManager?.workspacesById[preferredWorkspaceID],
           workspace.surfaceOwnershipTarget(for: surfaceID) != nil {
            return workspace
        }
        if let owner = AppDelegate.shared?.workspaceContainingPanel(
            panelId: surfaceID, preferredWorkspaceId: preferredWorkspaceID
        ) {
            return owner.workspace
        }
        return tabManager?.tabs.first { $0.surfaceOwnershipTarget(for: surfaceID) != nil }
    }

    /// `pane_id` / `surface_id` may be UUIDs or handle refs (`pane:3`, `surface:7`); the pure
    /// destination mapper needs pane UUIDs, so resolve refs here and turn a surface into the
    /// pane that holds it.
    nonisolated func surfaceResolvedParams(_ params: [String: Any]) -> [String: Any] {
        var resolved = params
        if let paneID = v2UUID(params, "pane_id") {
            resolved["pane_id"] = paneID.uuidString
        }
        if resolved["pane_id"] == nil, let surfaceID = v2UUID(params, "surface_id") {
            let preferredWorkspaceID = v2UUID(params, "workspace_id")
            let paneID = v2MainSync { () -> String? in
                guard let workspace = self.surfaceWorkspace(
                    containing: surfaceID, preferredWorkspaceID: preferredWorkspaceID
                ) else { return nil }
                return workspace.controlSurfaceTarget(for: surfaceID)?.paneID?.uuidString
            }
            if let paneID {
                resolved["pane_id"] = paneID
                resolved["surface_id"] = nil
            }
        }
        return resolved
    }

    /// Destination from the shared params: `pane_id` + `direction` → split that pane on that
    /// side; `pane_id` + `tab_index` (or `placement: tab`) → a tab in that pane; otherwise the
    /// workspace's focused pane (`placement`, default split). Pure.
    nonisolated static func surfaceDestination(_ params: [String: Any], workspaceID: UUID) -> SurfaceDestination {
        let paneID = surfaceString(params["pane_id"]) ?? surfaceString(params["surface_id"])
        let placement = surfaceString(params["placement"]).flatMap { SurfacePlacement(rawValue: $0.lowercased()) } ?? .split
        let direction = surfaceString(params["direction"]).flatMap { SurfaceSplitDirection(rawValue: $0.lowercased()) }
        let tabIndex = surfaceInt(params["tab_index"])
        if let paneID, let direction {
            return .split(workspaceID: workspaceID, paneID: paneID, direction: direction)
        }
        if let paneID, (tabIndex != nil || placement == .tab) {
            return .tab(workspaceID: workspaceID, paneID: paneID, index: tabIndex)
        }
        if let paneID {
            return .split(workspaceID: workspaceID, paneID: paneID, direction: .right)
        }
        return .workspace(id: workspaceID, placement: placement)
    }

    nonisolated static func surfaceMachineFilter(_ raw: Any?) -> SurfaceMachineID? {
        guard let value = surfaceString(raw), !value.isEmpty else { return nil }
        return SurfaceMachineID(rawValue: value)
    }

    // MARK: Wire payloads (snake_case; the same shape the CLI and the sidebar read)

    nonisolated static func surfaceCatalogPayload(_ export: SurfaceCatalogExport, machine: SurfaceMachineID?, remoteOnly: Bool = false) -> [String: Any] {
        let snapshot = export.catalog
        let machines = snapshot.machines.filter { info in
            if remoteOnly, info.id.isLocal { return false }
            if let machine { return info.id == machine }
            return true
        }
        let included = Set(machines.map { $0.id })
        let resources = snapshot.resources.filter { included.contains($0.machine) }
        let resourceIDs = Set(resources.map { $0.id })
        let projections = snapshot.projections.filter { resourceIDs.contains($0.resource) }
        var openPanels: [SurfaceResourceID: [SurfaceProjection]] = [:]
        for projection in projections {
            openPanels[projection.resource, default: []].append(projection)
        }
        return [
            "machines": machines.map { info in
                ["id": info.id.rawValue, "name": info.name, "status": info.status] as [String: Any]
            },
            "resources": resources.map { surfaceResourcePayload($0, projections: openPanels[$0.id] ?? []) },
            "projections": projections.map {
                surfaceProjectionPayload($0, identity: export.projectionIdentities[$0])
            },
        ]
    }

    nonisolated static func surfaceResourcePayload(_ resource: SurfaceResource, projections: [SurfaceProjection]) -> [String: Any] {
        var payload: [String: Any] = [
            "id": resource.id.rawValue,
            "machine": resource.machine.rawValue,
            "kind": resource.kind.rawValue,
            "key": resource.id.key,
            "title": resource.title,
            "detail": resource.detail ?? NSNull(),
            "lifecycle": resource.lifecycle.rawValue,
            "port": resource.port ?? NSNull(),
            "url": resource.url ?? NSNull(),
            "open": !projections.isEmpty,
            "open_surface_ids": projections.map { $0.panelID.uuidString },
            "open_workspace_ids": projections.map { $0.workspaceID.uuidString },
        ]
        if let agent = resource.agent {
            payload["agent"] = ["state": agent.state, "source": agent.source ?? NSNull()] as [String: Any]
        } else {
            payload["agent"] = NSNull()
        }
        return payload
    }

    nonisolated static func surfaceProjectionPayload(
        _ projection: SurfaceProjection,
        identity: SurfaceProjectionIdentity? = nil
    ) -> [String: Any] {
        [
            "resource": projection.resource.rawValue,
            "workspace_id": projection.workspaceID.uuidString,
            "panel_id": projection.panelID.uuidString,
            "surface_id": projection.panelID.uuidString,
            "stable_surface_id": identity?.stableSurfaceID.uuidString ?? NSNull(),
            "stable_workspace_id": identity?.stableWorkspaceID.uuidString ?? NSNull(),
            "remote_workspace_id": projection.remoteWorkspaceID ?? NSNull(),
            "remote_tab_id": projection.remoteTabID ?? NSNull(),
        ]
    }

    /// An open that did not take focus marks the pane it created unread, so the person
    /// sees that something landed without being pulled to it
    /// (`SurfacePaneFactory.markOpenedInBackground`). A reused pane was already there.
    /// Returns `payload` unchanged.
    nonisolated static func markBackgroundOpen(_ payload: [String: Any], focus: Bool) async -> [String: Any] {
        guard !focus, payload["reused"] as? Bool != true,
              let workspaceID = (payload["workspace_id"] as? String).flatMap(UUID.init(uuidString:)),
              let panelID = ((payload["surface_id"] as? String) ?? (payload["surface_ids"] as? [String])?.first)
                .flatMap(UUID.init(uuidString:)) else { return payload }
        await SurfacePaneFactory.markOpenedInBackground(panelID: panelID, in: workspaceID)
        return payload
    }

    nonisolated static func surfaceProjectPayload(_ projection: SurfaceProjection, reused: Bool) -> [String: Any] {
        [
            "resource": projection.resource.rawValue,
            "workspace_id": projection.workspaceID.uuidString,
            "surface_id": projection.panelID.uuidString,
            "panel_id": projection.panelID.uuidString,
            "reused": reused,
            "remote_workspace_id": projection.remoteWorkspaceID ?? NSNull(),
            "remote_tab_id": projection.remoteTabID ?? NSNull(),
        ]
    }

    // MARK: Param helpers (nonisolated; the worker parses before hopping to the main actor)

    nonisolated static func surfaceString(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Reads a required string while preserving an explicit empty value. Most
    /// identifiers use ``surfaceString`` because empty means missing there.
    /// Rename commands are different: an empty string is the wire-level clear
    /// operation, while a missing or null value is a malformed request.
    nonisolated static func surfaceStringPreservingEmpty(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func surfaceBool(_ raw: Any?) -> Bool? {
        if let value = raw as? Bool { return value }
        if let number = raw as? NSNumber { return number.boolValue }
        if let text = raw as? String {
            switch text.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }

    nonisolated static func surfaceInt(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let number = raw as? NSNumber { return number.intValue }
        if let text = raw as? String { return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    nonisolated static func surfaceStringArray(_ raw: Any?) -> [String] {
        guard let array = raw as? [Any] else { return [] }
        return array.compactMap { surfaceString($0) }
    }
}
