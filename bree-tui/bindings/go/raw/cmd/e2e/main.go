package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"

	bree "github.com/ecyx00/bree/bree-tui/bindings/go/raw"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	socket := socketFromEnv()
	if socket == "" {
		return fmt.Errorf("BREE_TUI_SOCKET is required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	client, err := bree.NewClient(bree.Options{
		SocketPath:            socket,
		Timeout:               5 * time.Second,
		AllowProtocolV6Attach: true,
	})
	if err != nil {
		return err
	}
	defer client.Close()

	marker := fmt.Sprintf("BREE_GO_E2E_%d_%d", os.Getpid(), time.Now().UnixNano())
	later := marker + "_ATTACH"
	info, err := client.Identify(ctx)
	if err != nil {
		return err
	}
	if info.App != "bree-tui" || info.Protocol < 5 || info.Protocol > 10 {
		return fmt.Errorf("unexpected identify result: %+v", info)
	}
	cols, rows := uint16(80), uint16(24)
	created, err := client.NewWorkspace(ctx, bree.NewWorkspaceOptions{
		Name: bree.Value(marker),
		Cols: bree.Value(cols),
		Rows: bree.Value(rows),
	})
	if err != nil {
		return err
	}
	text := fmt.Sprintf("printf '%s\\n'\r", marker)
	if err := client.Send(
		ctx,
		created.Surface,
		bree.SendOptions{Text: bree.Value(text)},
	); err != nil {
		return err
	}
	if err := waitForMarker(ctx, client, created.Surface, marker); err != nil {
		return err
	}
	screen, err := client.ReadScreen(ctx, created.Surface)
	if err != nil {
		return err
	}
	if !strings.Contains(screen.Text, marker) {
		return fmt.Errorf("marker missing from read-screen")
	}
	tree, err := client.ListWorkspaces(ctx)
	if err != nil {
		return err
	}
	workspace, ok := findWorkspaceForSurface(tree, created.Surface)
	if !ok {
		return fmt.Errorf("workspace not found")
	}
	pane, ok := findPaneForSurface(tree, created.Surface)
	if !ok {
		return fmt.Errorf("pane not found")
	}
	if _, err := client.Split(ctx, pane, bree.SplitDirectionRight, bree.SplitOptions{}); err != nil {
		return err
	}
	if err := client.SetRatio(ctx, pane, bree.SplitDirectionRight, 0.5); err != nil {
		return err
	}
	if err := client.RenameSurface(ctx, created.Surface, marker+"-renamed"); err != nil {
		return err
	}
	events, err := client.Subscribe(ctx)
	if err != nil {
		return err
	}
	defer events.Close()
	if _, err := client.ResizeSurface(ctx, created.Surface, 100, 31); err != nil {
		return err
	}
	resized, err := nextResized(events, created.Surface, time.Second)
	if err != nil {
		return err
	}
	if resized.Cols != 100 || resized.Rows != 31 {
		return fmt.Errorf("bad resize event: %+v", resized)
	}
	if _, err := client.ResizeSurface(ctx, created.Surface, 100, 31); err != nil {
		return err
	}
	if _, err := nextResized(events, created.Surface, 500*time.Millisecond); !errors.Is(err, bree.ErrTimeout) {
		return fmt.Errorf("same-size resize emitted event or failed oddly: %v", err)
	}

	attach, err := client.AttachSurfaceWithOptions(
		ctx,
		created.Surface,
		bree.AttachSurfaceOptions{
			Cols: bree.Value(cols),
			Rows: bree.Value(rows),
		},
	)
	if err != nil {
		return err
	}
	defer attach.Close()
	first, err := attach.Recv(ctx)
	if err != nil {
		return err
	}
	if first.EventName() != "vt-state" {
		return fmt.Errorf("first attach event was %s", first.EventName())
	}
	if info.Protocol >= 10 {
		sizingClient, size, ok, err := findClientSurfaceSize(ctx, client, created.Surface)
		if err != nil {
			return err
		}
		if !ok || !size.SizeParticipating {
			return fmt.Errorf("protocol 10 surface sizing state missing: %+v", size)
		}
		if err := client.SetClientSizing(
			ctx,
			created.Surface,
			false,
			bree.SetClientSizingOptions{Client: bree.Value(sizingClient)},
		); err != nil {
			return err
		}
		_, size, ok, err = findClientSurfaceSize(ctx, client, created.Surface)
		if err != nil {
			return err
		}
		if !ok || size.SizeParticipating {
			return fmt.Errorf("surface sizing mutation was not reflected: %+v", size)
		}
		if err := client.SetClientSizing(
			ctx,
			created.Surface,
			true,
			bree.SetClientSizingOptions{Client: bree.Value(sizingClient)},
		); err != nil {
			return err
		}
	}
	outputText := fmt.Sprintf("printf '%s\\n'\r", later)
	if err := client.Send(
		ctx,
		created.Surface,
		bree.SendOptions{Text: bree.Value(outputText)},
	); err != nil {
		return err
	}
	if err := nextAttachOutput(attach, 3*time.Second); err != nil {
		return err
	}
	if _, err := client.CloseWorkspaceByID(ctx, workspace); err != nil {
		return err
	}
	afterClose, err := client.ListWorkspaces(ctx)
	if err != nil {
		return err
	}
	if _, ok := findWorkspaceForSurface(afterClose, created.Surface); ok {
		return fmt.Errorf("closed workspace still present")
	}
	_, err = client.ReadScreen(ctx, created.Surface)
	var commandErr *bree.CommandError
	if !errors.As(err, &commandErr) || commandErr.Message == "" {
		return fmt.Errorf("closed surface error was not command error preserving message: %v", err)
	}
	return nil
}

func socketFromEnv() string {
	if socket := os.Getenv("BREE_TUI_SOCKET"); socket != "" {
		return socket
	}
	return os.Getenv("BREE_MUX_SOCKET")
}

func waitForMarker(ctx context.Context, client *bree.Client, surface uint64, marker string) error {
	deadline := time.Now().Add(5 * time.Second)
	last := ""
	for time.Now().Before(deadline) {
		screen, err := client.ReadScreen(ctx, surface)
		if err != nil {
			return err
		}
		last = screen.Text
		if strings.Contains(last, marker) {
			return nil
		}
		time.Sleep(50 * time.Millisecond)
	}
	return fmt.Errorf("marker not found; last screen: %q", last)
}

func nextResized(events *bree.Stream, surface uint64, timeout time.Duration) (bree.SurfaceResizedEvent, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	for {
		event, err := events.Recv(ctx)
		if err != nil {
			return bree.SurfaceResizedEvent{}, err
		}
		if resized, ok := event.(bree.SurfaceResizedEvent); ok && resized.Surface == surface {
			return resized, nil
		}
	}
}

func nextAttachOutput(events *bree.Stream, timeout time.Duration) error {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	for {
		event, err := events.Recv(ctx)
		if err != nil {
			return err
		}
		if event.EventName() == "output" || event.EventName() == "resized" {
			return nil
		}
	}
}

func findWorkspaceForSurface(tree bree.Tree, surface uint64) (uint64, bool) {
	for _, workspace := range tree.Workspaces {
		for _, screen := range workspace.Screens {
			for _, pane := range screen.Panes {
				live, ok := pane.AsLivePane()
				if !ok {
					continue
				}
				for _, tab := range live.Tabs {
					if tab.Surface == surface {
						return workspace.ID, true
					}
				}
			}
		}
	}
	return 0, false
}

func findPaneForSurface(tree bree.Tree, surface uint64) (uint64, bool) {
	for _, workspace := range tree.Workspaces {
		for _, screen := range workspace.Screens {
			for _, pane := range screen.Panes {
				live, ok := pane.AsLivePane()
				if !ok {
					continue
				}
				for _, tab := range live.Tabs {
					if tab.Surface == surface {
						return live.ID, true
					}
				}
			}
		}
	}
	return 0, false
}

func findScreenForSurface(tree bree.Tree, surface uint64) (bree.Screen, bool) {
	for _, workspace := range tree.Workspaces {
		for _, screen := range workspace.Screens {
			for _, pane := range screen.Panes {
				live, ok := pane.AsLivePane()
				if !ok {
					continue
				}
				for _, tab := range live.Tabs {
					if tab.Surface == surface {
						return screen, true
					}
				}
			}
		}
	}
	return bree.Screen{}, false
}

func findClientSurfaceSize(
	ctx context.Context,
	client *bree.Client,
	surface uint64,
) (uint64, bree.ClientSurfaceSize, bool, error) {
	clients, err := client.ListClients(ctx)
	if err != nil {
		return 0, bree.ClientSurfaceSize{}, false, err
	}
	for _, info := range clients {
		for _, size := range info.Sizes {
			if size.Surface == surface {
				return info.Client, size, true, nil
			}
		}
	}
	return 0, bree.ClientSurfaceSize{}, false, nil
}
