import Foundation
import Testing
import CmuxWorkspaces

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct ShellEditorModePolicyTests {
    private let base = ShellEditorModePolicy(
        settingEnabled: true,
        shellState: .promptIdle,
        alternateScreen: false,
        rawMode: false,
        textBoxActive: false,
        isLocal: true,
        awaitingPrompt: false
    )

    @Test("active at a local idle prompt")
    func activeBaseline() {
        #expect(base.isActive)
    }

    @Test("each blocker alone deactivates")
    func blockers() {
        var p = base; p.settingEnabled = false; #expect(!p.isActive)
        p = base; p.shellState = .unknown; #expect(!p.isActive)
        p = base; p.alternateScreen = true; #expect(!p.isActive)
        p = base; p.rawMode = true; #expect(!p.isActive)
        p = base; p.textBoxActive = true; #expect(!p.isActive)
        p = base; p.isLocal = false; #expect(!p.isActive)
    }

    @Test("a running command keeps the editor up in program input mode")
    func programInput() {
        var p = base; p.shellState = .commandRunning
        #expect(p.isActive)
        #expect(p.isProgramInput)
        #expect(!p.isCommandInput)
        // Submitted but not yet reported as running: same mode, no flash.
        p = base; p.awaitingPrompt = true
        #expect(p.isActive)
        #expect(p.isProgramInput)
        #expect(!base.isProgramInput)
    }

    @Test("alternate screen, raw mode, remote and unknown opt out while running")
    func programInputBlockers() {
        var running = base; running.shellState = .commandRunning
        var p = running; p.alternateScreen = true; #expect(!p.isActive)
        p = running; p.rawMode = true; #expect(!p.isActive)
        p = running; p.isLocal = false; #expect(!p.isActive)
        p = running; p.textBoxActive = true; #expect(!p.isActive)
        p = running; p.shellState = .unknown; #expect(!p.isActive)
        // Agent CLIs (claude, codex) have their own input box.
        p = running; p.agentForeground = true; #expect(!p.isActive)
    }

    @Test("password prompt = ECHO off while canonical; raw TUIs are not")
    func passwordPrompt() {
        #expect(ShellEditorProcessProbe.isPasswordPrompt(lflag: tcflag_t(ICANON)))
        #expect(!ShellEditorProcessProbe.isPasswordPrompt(lflag: tcflag_t(ICANON | ECHO)))
        #expect(!ShellEditorProcessProbe.isPasswordPrompt(lflag: 0))
    }

    @Test("agent command match on basename of exec path or argv")
    func agentMatch() {
        #expect(ShellEditorProcessProbe.isAgent(names: ["claude"]))
        #expect(ShellEditorProcessProbe.isAgent(names: ["node", "/opt/x/bin/codex"]))
        #expect(!ShellEditorProcessProbe.isAgent(names: ["python3", "claude-notes.py"]))
    }
}
