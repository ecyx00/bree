import SwiftUI

/// The settings detail stack, split out of `SettingsWindowScene.swift`.
/// Sections mount progressively through ``SettingsSectionMountModel``
/// (https://github.com/ecyx00/bree/issues/12134): the one the window
/// opens on in the first layout pass, the rest one per run-loop turn.
extension SettingsWindowRoot {
    /// Sections a window opening now mounts progressively. Cloud stays
    /// eager while unavailable: it renders nothing, so a placeholder would
    /// only advertise a section the sidebar hides.
    static func mountOrder(cloudAvailable: Bool) -> [SettingsSectionID] {
        SettingsSectionMountModel.displayOrder.filter { $0 != .cloudMachines || cloudAvailable }
    }

    func anchorID(for section: SettingsSectionID) -> String {
        "section:\(section.rawValue)"
    }

    @ViewBuilder
    func sectionStack(proxy: ScrollViewProxy) -> some View {
        // Top to bottom in ``SettingsSectionMountModel/displayOrder``. Hosted
        // sections render inside their host slot: Global Hotkey in App,
        // TextBox in Terminal, Workspace Colors in Sidebar, Browser Import in
        // Browser; bree.json and Reset in Advanced.
        slot(.app, proxy: proxy) {
            AppSection(
                defaultsStore: defaultsStore,
                catalog: catalog,
                hostActions: hostActions,
                soundAgentCache: soundAgentCache
            )
            GlobalHotkeySection(
                defaultsStore: defaultsStore,
                jsonStore: jsonStore,
                catalog: catalog, errorLog: runtime.errorLog,
                hostActions: hostActions,
                defaultShortcutResolver: runtime.shortcutDefaultResolver
            )
        }

        slot(.themes, proxy: proxy) {
            ThemesSection(
                defaultsStore: defaultsStore,
                jsonStore: jsonStore,
                catalog: catalog,
                errorLog: runtime.errorLog,
                hostActions: hostActions
            )
        }

        slot(.terminal, proxy: proxy) {
            TerminalSection(
                defaultsStore: defaultsStore,
                jsonStore: jsonStore,
                catalog: catalog,
                hostActions: hostActions
            )
            TextBoxSection(defaultsStore: defaultsStore, catalog: catalog)
        }

        slot(.cloudMachines, proxy: proxy) {
            // `DisableCloud` (MDM) and the rollout gate: no Cloud pane at all
            // while unavailable, not just no placeholder.
            if isCloudSectionAvailable {
                CloudMachinesSection(hostActions: hostActions)
                    .id(cloudSectionIdentity)
            }
        }

        slot(.sidebarAppearance, proxy: proxy) {
            SidebarSection(defaultsStore: defaultsStore, catalog: catalog, hostActions: hostActions)
            WorkspaceColorsSection(
                defaultsStore: defaultsStore,
                jsonStore: jsonStore,
                catalog: catalog,
                errorLog: runtime.errorLog
            )
        }

        slot(.automation, proxy: proxy) {
            AutomationSection(
                defaultsStore: defaultsStore,
                jsonStore: jsonStore,
                secretStore: secretStore,
                catalog: catalog,
                errorLog: runtime.errorLog,
                hostActions: hostActions
            )
        }

        slot(.browser, proxy: proxy) {
            BrowserSection(
                defaultsStore: defaultsStore,
                catalog: catalog,
                hostActions: hostActions,
                importAnchorID: anchorID(for: .browserImport)
            )
        }

        slot(.keyboardShortcuts, proxy: proxy) {
            KeyboardShortcutsSection(
                jsonStore: jsonStore, userDefaultsStore: defaultsStore,
                catalog: catalog,
                errorLog: runtime.errorLog,
                hostActions: hostActions,
                defaultShortcutResolver: runtime.shortcutDefaultResolver,
                keymapProposals: runtime.keymapProposals
            )
        }

        slot(.wiki, proxy: proxy) {
            WikiSection()
        }

        slot(.advanced, proxy: proxy) {
            RemoteTmuxSettingsCard(defaultsStore: defaultsStore, catalog: catalog)
            SettingsJSONSection(jsonStore: jsonStore, hostActions: hostActions)
            ResetSection(
                defaultsStore: defaultsStore,
                jsonStore: jsonStore,
                catalog: catalog,
                hostActions: hostActions
            )
        }
    }

    private func slot<Content: View>(
        _ section: SettingsSectionID,
        proxy: ScrollViewProxy,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        SettingsSectionSlot(
            section: section,
            isActive: section == SettingsSectionMountModel.hostSection(for: activeSection),
            isMounted: mountModel.isMounted(section),
            showsPlaceholder: section != .cloudMachines || isCloudSectionAvailable,
            onMountedAppear: { sectionContentDidAppear(section, proxy: proxy) },
            content: content
        )
    }

    /// A mounted section's content is in the hierarchy: `onAppear` runs
    /// inside the update that laid it out, before that frame commits.
    /// `scrollTo` resolves against the layout that exists when it is called,
    /// so this is the moment to scroll: a navigation deferred to this
    /// section can reach its rows now, and the committed frame never shows
    /// the pane at the previous pane's offset. The next section then mounts
    /// one main-actor hop later, in a later update pass.
    func sectionContentDidAppear(_ section: SettingsSectionID, proxy: ScrollViewProxy) {
        shownPaneSection = section
        if let deferred = mountModel.takeDeferredScroll(for: section),
           deferred.generation == settingsNavigationGeneration {
            proxy.scrollTo(deferred.anchorID, anchor: deferred.anchor)
        }
        Task { @MainActor in
            _ = mountModel.sectionDidAppear(section)
        }
    }
}
