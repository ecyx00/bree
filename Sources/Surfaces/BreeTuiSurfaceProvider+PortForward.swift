import BreeCloud
import BreeSurfaceCatalogModel
import Foundation

extension BreeTuiSurfaceProvider {
    /// Create the browser with native connection state before attempting access.
    /// The authenticated userspace proxy keeps each VM's address and port.
    func materializeBrowserPane(
        _ resource: SurfaceResource,
        at destination: SurfaceDestination,
        focus: Bool,
        reusing existingPane: (workspaceID: UUID, panelID: UUID)? = nil
    ) async throws -> (workspaceID: UUID, panelID: UUID) {
        try Task.checkCancellation()
        try catalog.validateOwnership(of: [resource.id], at: destination)
        guard isRegisteredInCatalog() else { throw CancellationError() }
        let pane = try existingPane
            ?? CloudDisplayPaneReservation.current?.pane(for: resource)
            ?? SurfacePaneFactory.makeBrowserPane(url: nil, at: destination, focus: focus)
        guard let browser = SurfacePaneFactory.browserPanel(panelID: pane.panelID, in: pane.workspaceID) else {
            throw ProviderError.localForwardURLUnavailable
        }
        switch CloudPortRoutePlan.plan(resource: resource, privateAddress: info.privateAddress) {
        case .privateDirect(let raw):
            guard let url = URL(string: raw) else { throw ProviderError.localForwardURLUnavailable }
            configureBrowser(browser, url: url, resourceID: resource.id)
        case .unsupported(let message):
            showPortUnavailable(message, resourceID: resource.id, browser: browser)
        }
        return pane
    }

    /// Bind the page to its machine proxy without activating a system VPN.
    @discardableResult
    func configureBrowser(_ browser: BrowserPanel, url: URL, resourceID: SurfaceResourceID? = nil,
                          preserveCurrentNavigation: Bool = false) -> Bool {
        let requestedPort = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        let fallbackID: SurfaceResourceID = if info.hasDesktop, (BreeTuiSnapshotParser.desktopPort...6916).contains(requestedPort) {
            SurfaceResourceID(machine: machine, kind: .display, key: "display:\(requestedPort - 6900)")
        } else {
            SurfaceResourceID(machine: machine, kind: .browser, key: "port:\(requestedPort)")
        }
        let projectedResource = catalog.projectionRecord(forPanel: browser.id).flatMap {
            $0.resource.machine.isLocal ? nil : $0.resource
        }
        let retainedResource = browser.cloudAccess.resourceID ?? projectedResource
        let explicitResource: SurfaceResourceID?
        if let resourceID {
            explicitResource = resourceID
        } else if let retainedResource,
                  Self.port(for: retainedResource, catalog: catalog) == nil
                    || Self.port(for: retainedResource, catalog: catalog) == requestedPort {
            explicitResource = retainedResource
        } else {
            // A URL that changes the service port must resolve to the requested
            // catalog slot instead of carrying the old display identity forward.
            explicitResource = nil
        }
        if let explicitResource,
           let expectedPort = Self.port(for: explicitResource, catalog: catalog),
           expectedPort != requestedPort {
            browser.cloudAccess.showUnavailable(CloudGuestDisplaySnapshot.unavailableMessage)
            return false
        }
        if explicitResource == nil, fallbackID.kind == .display,
           fallbackID.key != SurfaceResourceID.desktopDisplayKey,
           catalog.resources[fallbackID] == nil {
            browser.cloudAccess.showUnavailable(CloudGuestDisplaySnapshot.unavailableMessage)
            return false
        }
        let resourceID = explicitResource ?? fallbackID
        let destinationOwned = (try? catalog.validateOwnership(of: [resourceID], at: .workspace(id: browser.workspaceId, placement: .tab))) != nil
        guard resourceID.machine == machine,
              browser.cloudAccess.resourceID?.machine == nil || browser.cloudAccess.resourceID?.machine == machine,
              destinationOwned else {
            browser.cloudAccess.showUnavailable(SurfaceTransferRejection.cloudMachineMismatch.message)
            return false
        }
        guard let address = info.privateAddress,
              let privateURL = CloudPortRoutePolicy().privateURL(url.absoluteString, address: address, allowLoopback: machine.isSSH) else {
            browser.cloudAccess.showUnavailable(String(localized: "cloud.portAccess.invalidURL", defaultValue: "This port does not have a valid HTTP or HTTPS address."))
            return false
        }
        // Check the VM origin before rewriting it to localhost. Otherwise the
        // implicit localhost allowance could bypass a private-origin deny rule.
        guard browserPolicy().allowsTrustedInternalURL(privateURL) else {
            browser.cloudAccess.showUnavailable(String(localized: "browser.error.urlAllowlist.userMessage", defaultValue: "This URL is not allowed by the embedded-browser URL policy."))
            return false
        }
        if let existing = catalog.projectionRecord(forPanel: browser.id), existing.resource != resourceID {
            catalog.endProjections(panelID: browser.id, reason: .replaced)
            catalog.restore([SurfaceProjectionRecord(panelID: browser.id, resource: resourceID)], workspaceID: browser.workspaceId)
        }
        let port = privateURL.port ?? (privateURL.scheme?.lowercased() == "https" ? 443 : 80)
        let model = accessModel(port: port, address: address, scheme: privateURL.scheme ?? "http")
        browser.retainTransferredSurfaceMachine(machine)
        if preserveCurrentNavigation {
            browser.prepareCloudBrowserStore(machineID: machineID)
            browser.bindCloudBrowserNavigation()
            browser.cloudAccess.adoptCommittedRoute(model: model, url: privateURL, resourceID: resourceID)
            model.connect()
        } else {
            browser.configureCloudBrowser(model: model, url: privateURL, resourceID: resourceID)
        }
        materializedPanels.insert(browser.id)
        return true
    }

    private static func port(for resource: SurfaceResourceID, catalog: SurfaceCatalog) -> Int? {
        if let port = catalog.resources[resource]?.port { return port }
        if resource.kind == .display,
           let number = Int(resource.key.split(separator: ":").last ?? ""), (1...16).contains(number) {
            return 6900 + number
        }
        if resource.kind == .browser, resource.key.hasPrefix("port:"),
           let port = Int(resource.key.dropFirst("port:".count)) {
            return port
        }
        return nil
    }

    /// Re-runs the authoritative machine refresh before retrying a route that
    /// was unavailable at materialization time (most commonly a withdrawn
    /// private address). The browser card therefore always has a real retry
    /// action instead of leaving the user on a dead loading surface.
    private func showPortUnavailable(_ message: String, resourceID: SurfaceResourceID, browser: BrowserPanel) {
        browser.cloudAccess.showUnavailable(message) { [weak self, weak browser] request in
            guard let self, let browser, self.isRegisteredInCatalog() else { return }
            let lifecycle = self.currentLifecycleGeneration
            do {
                try await self.refreshPortMetadata()
                guard self.isCurrentLifecycleGeneration(lifecycle), self.isRegisteredInCatalog(),
                      browser.cloudAccess.isCurrentUnavailableRetry(request) else { return }
                let resource = self.catalog.resources[resourceID]
                    ?? resourceID.forwardedPort.map { BreeTuiSnapshotParser.portBrowser(machine: self.machine, port: $0) }
                guard let resource, resource.machine == self.machine else { throw SurfaceCatalogError.unknownResource(resourceID) }
                switch CloudPortRoutePlan.plan(resource: resource, privateAddress: self.info.privateAddress) {
                case .privateDirect(let raw):
                    guard let url = URL(string: raw) else { throw ProviderError.invalidPreviewURL }
                    self.configureBrowser(browser, url: url)
                case .unsupported(let nextMessage):
                    self.showPortUnavailable(nextMessage, resourceID: resourceID, browser: browser)
                }
            } catch {
                guard self.isCurrentLifecycleGeneration(lifecycle), self.isRegisteredInCatalog(),
                      browser.cloudAccess.isCurrentUnavailableRetry(request) else { return }
                self.showPortUnavailable(CloudDiagnosticFailure.classify(error).label, resourceID: resourceID, browser: browser)
            }
        }
    }

    /// Browser panes always use the machine's authenticated browser proxy
    /// (SSH carrier); there is no private-network or hub-forward route.
    func accessModel(port: Int, address: String, scheme: String = "http") -> CloudPortAccessModel {
        let target = CloudPortForwardTarget(host: address, port: port)
        return portAccessStore.model(machineID: machineID, target: target, scheme: scheme) {
            CloudPortAccessModel(
                target: target,
                coordinator: nil,
                wake: { [weak self] in
                    guard let self, self.isRegisteredInCatalog() else { throw CancellationError() }
                },
                startForward: { _ in throw ProviderError.hubUnavailable },
                stopForward: {},
                startBrowserProxy: { [weak self] in
                    guard let self, self.isRegisteredInCatalog() else { throw ProviderError.hubUnavailable }
                    let generation = self.currentLifecycleGeneration
                    let endpoint = try await self.links.browserProxy(machineID: self.machineID)
                    guard self.isCurrentLifecycleGeneration(generation), self.isRegisteredInCatalog() else { throw CancellationError() }
                    return endpoint
                }
            )
        }
    }

    /// Rebinds browser panes for the supplied resources, or all restored browser panes.
    func reprojectRestoredBrowserPanes(generation: UInt64, resourceIDs: Set<SurfaceResourceID>? = nil) {
        let projectionsByResource = resourceIDs.map { catalog.projections(of: $0) }
        for resource in catalog.snapshot.resources(on: machine) where
            resource.kind != .terminal && (resourceIDs == nil || resourceIDs!.contains(resource.id)) {
            for projection in (resourceIDs == nil ? catalog.projections(of: resource.id) : projectionsByResource?[resource.id] ?? []) where !materializedPanels.contains(projection.panelID) {
                guard let browser = SurfacePaneFactory.browserPanel(panelID: projection.panelID, in: projection.workspaceID),
                      isCurrentLifecycleGeneration(generation), catalog.canRestoreProjection(projection) else { continue }
                switch CloudPortRoutePlan.plan(resource: resource, privateAddress: info.privateAddress) {
                case .privateDirect(let raw):
                    guard let url = URL(string: raw) else { continue }
                    let configured = configureBrowser(
                        browser,
                        url: browser.cloudRestoreURL(on: url),
                        resourceID: resource.id
                    )
                    if configured {
                        browser.pendingCloudRestoreURL = nil
                        materializedPanels.insert(projection.panelID)
                    }
                case .unsupported(let message):
                    if resource.id.isForwardedPort {
                        showPortUnavailable(message, resourceID: resource.id, browser: browser)
                    }
                    // Keep the placeholder eligible for a later explicit display
                    // discovery; its target may be supplied by the guest catalog.
                    continue
                }
            }
        }
    }
}
