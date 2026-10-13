import Foundation

struct ClaudeLaunchArgumentsPreserver {
    private let preserveOptions: ([String], AgentLaunchSanitizer.Policy) -> [String]?

    init(
        preserveOptions: @escaping ([String], AgentLaunchSanitizer.Policy) -> [String]? = AgentLaunchSanitizer.preserveOptions
    ) {
        self.preserveOptions = preserveOptions
    }

    func preservedArguments(
        args: [String],
        stripBreeHookSettings: Bool = true
    ) -> [String]? {
        var policy = AgentLaunchSanitizer.claudePolicy
        policy.skipClaudeHookSettings = stripBreeHookSettings
        return preserveOptions(args, policy)
    }
}
