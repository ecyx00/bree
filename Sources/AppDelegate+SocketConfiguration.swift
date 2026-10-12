import CmuxControlSocket
import CmuxSettings
import Foundation

extension AppDelegate {
    func reconcileSocketListenerConfiguration(source: String) {
        TerminalController.shared.reconcileSocketConfiguration(
            resolvedSocketListenerConfiguration(),
            routingFallbackTabManager: activeTabManagerForCommands(),
            source: source
        )
    }

    private func resolvedSocketListenerConfiguration() -> SocketControlServerConfiguration {
        return SocketControlServerConfiguration(
            accessMode: CmuxSettingsFileStore.liveSocketAccessMode(),
            preferredSocketPath: SocketControlSettings.socketPath()
        )
    }

    func socketListenerConfigurationIfEnabled() -> SocketControlServerConfiguration? {
        let configuration = resolvedSocketListenerConfiguration()
        return configuration.accessMode == .off ? nil : configuration
    }

    func reserveInitialSocketPathIfNeeded() {
        guard let config = socketListenerConfigurationIfEnabled() else { return }
        let startupPath = SocketControlSettings.initialSocketPathBeforeListenerStart(
            preferredPath: config.preferredSocketPath,
            stableDefaultSocketCanBeReclaimed: socketTransport.pathCanBeReclaimedForStartup
        )
        TerminalController.shared.reserveStartupSocketPath(startupPath)
    }

    func startSocketListenerIfEnabled(tabManager: TabManager, source: String) {
        guard let config = socketListenerConfigurationIfEnabled() else {
            TerminalController.shared.stop(cleanupDiscoveryState: true)
            return
        }
        TerminalController.shared.reconcileSocketConfiguration(
            config,
            routingFallbackTabManager: tabManager,
            source: source
        )
    }

    func ensureSocketListenerIfEnabled(tabManager: TabManager, source: String) {
        guard let config = socketListenerConfigurationIfEnabled() else {
            TerminalController.shared.stop(cleanupDiscoveryState: true)
            return
        }

        let path = TerminalController.shared.activeSocketPath(
            preferredPath: config.preferredSocketPath
        )
        let health = TerminalController.shared.socketListenerHealth(expectedSocketPath: path)
        guard !health.isHealthy else {
            TerminalController.shared.reconcileSocketConfiguration(
                config,
                routingFallbackTabManager: tabManager,
                source: source
            )
            return
        }

        TerminalController.shared.reconcileSocketConfiguration(
            config,
            routingFallbackTabManager: tabManager,
            source: source
        )
    }

    func restartSocketListenerIfEnabled(source: String) {
        guard let config = socketListenerConfigurationIfEnabled() else {
            TerminalController.shared.stop(cleanupDiscoveryState: true)
            return
        }
        let manager = activeTabManagerForCommands()
        let restartPath = TerminalController.shared.activeSocketPath(
            preferredPath: config.preferredSocketPath
        )
        TerminalController.shared.stop(cleanupDiscoveryState: false)
        TerminalController.shared.startSocketTransport(
            config,
            socketPath: restartPath,
            routingFallbackTabManager: manager
        )
    }
}
