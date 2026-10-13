import BREEAgentLaunch
import Testing

@Suite("CLIForwardingDecision")
struct CLIForwardingDecisionTests {
    /// A CLI invocation that reaches the GUI binary with the forwarding
    /// guard already set must not fall through to a GUI launch: hook
    /// commands (`bree claude-hook …`) would each leave a faceless app
    /// instance running forever.
    @Test("CLI argv with the guard set fails closed")
    func cliArgvWithGuardSetFailsClosed() {
        #expect(
            CLIForwardingDecision(
                arguments: ["bree", "claude-hook", "pre-tool-use"],
                forwardingGuardIsSet: true
            ) == .failForwardingLoop
        )
        #expect(
            CLIForwardingDecision(
                arguments: ["bree", "claude-hook", "pre-tool-use"],
                forwardingGuardIsSet: false
            ) == .forwardToBundledCLI
        )
    }

    /// GUI-style launches (no subcommand, `-psn_...` flags, `bree://` URLs,
    /// launch sentinels) stay in the app regardless of the forwarding guard.
    @Test("GUI argv launches the app even with the guard set")
    func guiArgvLaunchesAppEvenWithGuardSet() {
        #expect(
            CLIForwardingDecision(arguments: ["bree"], forwardingGuardIsSet: true) == .launchGUI
        )
        #expect(
            CLIForwardingDecision(
                arguments: ["bree", "-psn_0_12345"],
                forwardingGuardIsSet: true
            ) == .launchGUI
        )
        #expect(
            CLIForwardingDecision(
                arguments: ["bree", "bree://workspace/foo"],
                forwardingGuardIsSet: true
            ) == .launchGUI
        )
        #expect(
            CLIForwardingDecision(
                arguments: ["Bree Dev", "DEV"],
                forwardingGuardIsSet: true
            ) == .launchGUI
        )
        #expect(
            CLIForwardingDecision(
                arguments: ["bree RC", "RC"],
                forwardingGuardIsSet: true
            ) == .launchGUI
        )
    }

    /// CLI-style subcommands forward to the bundled CLI on the first pass.
    @Test("CLI subcommands forward to the bundled CLI")
    func cliSubcommandsForward() {
        #expect(CLIForwardingDecision.shouldForwardToBundledCLI(arguments: ["bree", "wait-for", "workspace:1"]))
        #expect(CLIForwardingDecision.shouldForwardToBundledCLI(arguments: ["bree", "hooks", "setup"]))
        #expect(!CLIForwardingDecision.shouldForwardToBundledCLI(arguments: ["bree", "-psn_0_12345"]))
        #expect(!CLIForwardingDecision.shouldForwardToBundledCLI(arguments: ["bree", "bree://workspace/foo"]))
    }
}
