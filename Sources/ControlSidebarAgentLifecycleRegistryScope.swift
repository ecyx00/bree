import Foundation

enum ControlSidebarAgentLifecycleRegistryScope: Sendable {
    case project(String?)
    case globalOnly

    func loadRegistry(
        homeDirectory: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> BreeVaultAgentRegistry {
        switch self {
        case .project(let workingDirectory):
            return BreeVaultAgentRegistry.load(
                homeDirectory: homeDirectory,
                workingDirectory: workingDirectory,
                environment: environment,
                fileManager: fileManager
            )
        case .globalOnly:
            return BreeVaultAgentRegistry.load(
                homeDirectory: homeDirectory,
                environment: [:],
                fileManager: fileManager
            )
        }
    }
}
