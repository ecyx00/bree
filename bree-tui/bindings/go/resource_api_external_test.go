package bree_test

import (
	"context"
	"testing"

	bree "github.com/ecyx00/bree/bree-tui/bindings/go"
	"github.com/ecyx00/bree/bree-tui/bindings/go/raw"
)

func TestResourceCollectionsExposePointerHandles(t *testing.T) {
	var _ func(*bree.Client, bree.Selector[bree.SessionID]) *bree.Session = (*bree.Client).Session
	var _ func(*bree.Client, context.Context, bree.MachineListOptions) ([]*bree.Machine, error) = (*bree.Client).ListMachines
	var _ func(*bree.Client, context.Context, string) ([]*bree.Machine, error) = (*bree.Client).FindMachinesByName
	var _ func(*bree.Machine, context.Context, bree.SessionListOptions) ([]*bree.Session, error) = (*bree.Machine).ListSessions
	var _ func(*bree.Machine, context.Context, string) ([]*bree.Session, error) = (*bree.Machine).FindSessionsByName
	var _ func(*bree.Session, context.Context, bree.WorkspaceListOptions) ([]*bree.Workspace, error) = (*bree.Session).ListWorkspaces
	var _ func(*bree.Session, context.Context, string) ([]*bree.Workspace, error) = (*bree.Session).FindWorkspacesByName
	var _ func(*bree.Workspace, context.Context, bree.ScreenListOptions) ([]*bree.Screen, error) = (*bree.Workspace).ListScreens
	var _ func(*bree.Workspace, context.Context, string) ([]*bree.Screen, error) = (*bree.Workspace).FindScreensByName
	var _ func(*bree.Screen, context.Context, bree.PaneListOptions) ([]*bree.Pane, error) = (*bree.Screen).ListPanes
	var _ func(*bree.Screen, context.Context, string) ([]*bree.Pane, error) = (*bree.Screen).FindPanesByName
	var _ func(*bree.Pane, context.Context, bree.TabListOptions) ([]*bree.Tab, error) = (*bree.Pane).ListTabs
	var _ func(*bree.Pane, context.Context, string) ([]*bree.Tab, error) = (*bree.Pane).FindTabsByName
	var _ func(*bree.Session, context.Context, bree.TerminalListOptions) ([]*bree.Terminal, error) = (*bree.Session).ListTerminals
	var _ func(*bree.Session, context.Context, string) ([]*bree.Terminal, error) = (*bree.Session).FindTerminalsByName
	var _ func(*bree.Session, context.Context, bree.BrowserListOptions) ([]*bree.Browser, error) = (*bree.Session).ListBrowsers
	var _ func(*bree.Session, context.Context, string) ([]*bree.Browser, error) = (*bree.Session).FindBrowsersByName
	var _ func(*bree.Session, bree.Selector[bree.TerminalID]) *bree.Terminal = (*bree.Session).Terminal
	var _ func(*bree.Session, bree.Selector[bree.BrowserID]) *bree.Browser = (*bree.Session).Browser
}

func TestCatalogResultMethodsCompileForExternalConsumers(t *testing.T) {
	var _ string = (bree.ConfirmationRequiredDetails{}).ConfirmationToken
	var _ func(*bree.Session, context.Context, bree.SessionSnapshotOptions) (bree.ResourceSnapshot, error) = (*bree.Session).Snapshot
	var _ func(*bree.Session, context.Context, string, bree.SessionCreationResolveOptions) (bree.CreationResolution, error) = (*bree.Session).ResolveCreation
	var _ func(*bree.Session, context.Context, bree.SessionPingOptions) (bree.PingResult, error) = (*bree.Session).Ping
	var _ func(*bree.Session, context.Context, bree.SessionShutdownOptions) (bree.MutationResult[bree.ShutdownResult], error) = (*bree.Session).Shutdown
	var _ func(*bree.Session, context.Context, bree.SessionReloadConfigOptions) (bree.MutationResult[bree.ReloadConfigResult], error) = (*bree.Session).ReloadConfig
	var _ func(*bree.Session, context.Context, bree.SessionTerminalDefaultsUpdateOptions) (bree.MutationResult[bree.TerminalDefaultsSnapshot], error) = (*bree.Session).UpdateTerminalDefaults
	var _ func(*bree.Terminal, context.Context, bree.TerminalScreenReadOptions) (bree.TerminalScreenResult, error) = (*bree.Terminal).ReadScreen
	var _ func(*bree.Terminal, context.Context, bree.TerminalStateReadOptions) (bree.TerminalStateResult, error) = (*bree.Terminal).ReadState
	var _ func(*bree.Terminal, context.Context, bree.TerminalHistoryReadOptions) (bree.TerminalHistoryResult, error) = (*bree.Terminal).ReadHistory
	var _ func(*bree.Terminal, context.Context, bree.TerminalWaitOptions) (bree.TerminalWaitResult, error) = (*bree.Terminal).Wait
	var _ func(*bree.Terminal, context.Context, bree.TerminalWaitExitOptions) (bree.TerminalWaitExitResult, error) = (*bree.Terminal).WaitExit
	var _ func(*bree.Terminal, context.Context, bree.TerminalCopyOptions) (bree.TerminalCopyResult, error) = (*bree.Terminal).Copy
	var _ func(*bree.Terminal, context.Context, bree.TerminalProcessGetOptions) (bree.ProcessInfoResult, error) = (*bree.Terminal).Process
	var _ func(*bree.Terminal, context.Context, bree.TerminalViewerResizeOptions) (bree.ViewerResizeResult, error) = (*bree.Terminal).ResizeViewer
	var _ func(*bree.Browser, context.Context, bree.BrowserViewerResizeOptions) (bree.BrowserViewerResizeResult, error) = (*bree.Browser).ResizeViewer
	var _ func(*bree.ConnectedClient, context.Context, bree.ConnectedClientCellPixelsSetOptions) (bree.CellPixelsResult, error) = (*bree.ConnectedClient).SetCellPixels
	var _ func(*bree.Workspace, context.Context, bree.WorkspaceRenameOptions) (bree.MutationResult[*bree.Workspace], error) = (*bree.Workspace).Rename
	var _ func(*bree.Screen, context.Context, bree.ScreenRenameOptions) (bree.MutationResult[*bree.Screen], error) = (*bree.Screen).Rename
	var _ func(*bree.Pane, context.Context, bree.PaneRenameOptions) (bree.MutationResult[*bree.Pane], error) = (*bree.Pane).Rename
	var _ func(*bree.Tab, context.Context, bree.TabRenameOptions) (bree.MutationResult[*bree.Tab], error) = (*bree.Tab).Rename
	var _ func(*bree.Terminal, context.Context, bree.TerminalMoveOptions) (bree.MutationResult[*bree.Terminal], error) = (*bree.Terminal).Move
	var _ func(*bree.Browser, context.Context, bree.BrowserNavigateOptions) (bree.MutationResult[*bree.Browser], error) = (*bree.Browser).Navigate
	var _ func(*bree.PairingRequest, context.Context, bree.PairingRequestResolveOptions) (bree.MutationResult[*bree.PairingRequest], error) = (*bree.PairingRequest).Resolve
	var _ func(*bree.FrontendProjection, context.Context, bree.FrontendProjectionPutOptions) (bree.MutationResult[*bree.FrontendProjection], error) = (*bree.FrontendProjection).Put
	var _ func(*bree.Session, context.Context, bree.AgentReportOptions) (bree.MutationResult[*bree.Agent], error) = (*bree.Session).ReportAgent
	var _ func(*bree.SidebarView, context.Context, bree.SidebarViewResizeOptions) (bree.MutationResult[*bree.SidebarView], error) = (*bree.SidebarView).Resize
}

func externalConsumerCompiles(
	client *bree.Client,
	highLevel bree.WorkspaceID,
	lowLevel *raw.Client,
) {
	_ = client.Machine(bree.SelectCurrent[bree.MachineID]()).
		Session(bree.SelectCurrent[bree.SessionID]()).
		Workspace(bree.SelectID(highLevel))
	_, _ = lowLevel.Identify(context.Background())
}
