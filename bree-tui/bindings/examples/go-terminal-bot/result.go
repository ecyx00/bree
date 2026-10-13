package terminalbot

import (
	"fmt"

	bree "github.com/ecyx00/bree/bree-tui/bindings/go"
)

// Result contains typed resource IDs and captured terminal state.
type Result struct {
	Workspace    bree.WorkspaceID
	Screen       bree.ScreenID
	Pane         bree.PaneID
	Tab          bree.TabID
	Terminal     bree.TerminalID
	Notification bree.NotificationID

	WorkspaceRevision bree.Decimal
	TerminalRevision  bree.Decimal
	ExitCode          int
	ScreenText        string
	HistoryText       string
	Warnings          []string
}

// TaskError reports a completed command with a nonzero exit status.
type TaskError struct {
	ExitCode int
}

func (err *TaskError) Error() string {
	return fmt.Sprintf("terminal task exited with status %d", err.ExitCode)
}
