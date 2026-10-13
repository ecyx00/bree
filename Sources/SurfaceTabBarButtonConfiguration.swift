import BreeSettings

struct SurfaceTabBarButtonConfiguration {
    let buttons: [BreeSurfaceTabBarButton]
    let sourcePath: String?
    let globalConfigPath: String
    let settingPresets: [String: BreeSettingValue]
    let terminalCommandSourcePaths: [String: String]
    let workspaceCommands: [String: BreeResolvedCommand]
}
