package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	bree "github.com/ecyx00/bree/bree-tui/bindings/go"
)

type constants struct {
	Machine        string `json:"machine"`
	Session        string `json:"session"`
	Workspace      string `json:"workspace"`
	Screen         string `json:"screen"`
	Pane           string `json:"pane"`
	Tab            string `json:"tab"`
	Terminal       string `json:"terminal"`
	Browser        string `json:"browser"`
	Generation     string `json:"generation"`
	Revision       string `json:"revision"`
	ExitRevision   string `json:"exit_revision"`
	ExitedAt       string `json:"exited_at"`
	IdempotencyKey string `json:"idempotency_key"`
	CorrelationKey string `json:"correlation_key"`
	Name           string `json:"name"`
}

type createdPathInput struct {
	Kind      string `json:"kind"`
	Workspace string `json:"workspace_id"`
	Screen    string `json:"screen_id"`
	Pane      string `json:"pane_id"`
	Tab       string `json:"tab_id"`
	Terminal  string `json:"terminal_id"`
	Browser   string `json:"browser_id"`
}

type request struct {
	ContractVersion            int              `json:"contract_version"`
	ID                         string           `json:"id"`
	Op                         string           `json:"op"`
	SocketPath                 string           `json:"socket_path"`
	Dimension                  string           `json:"dimension"`
	WorkspaceName              string           `json:"workspace_name"`
	KeyPrefix                  string           `json:"key_prefix"`
	ExpectedStableID           string           `json:"expected_stable_id"`
	ExpectedDuplicateIDs       []string         `json:"expected_duplicate_ids"`
	ExpectedCreatedPath        createdPathInput `json:"expected_created_path"`
	ExpectedCorrelationKey     string           `json:"expected_correlation_key"`
	ExpectedCreationGeneration string           `json:"expected_creation_generation"`
	ExpectedCreationRevision   string           `json:"expected_creation_revision"`
	ExpectedExitedAt           string           `json:"expected_exited_at"`
	ExpectedExitRevision       string           `json:"expected_exit_revision"`
	ExitShell                  string           `json:"exit_shell"`
	PendingTimeoutMS           string           `json:"pending_timeout_ms"`
	ExitTimeoutMS              string           `json:"exit_timeout_ms"`
	TimeoutMS                  string           `json:"timeout_ms"`
	ExpectedExitCode           int              `json:"expected_exit_code"`
	Constants                  constants        `json:"constants"`
}

type response struct {
	ContractVersion int           `json:"contract_version"`
	ID              string        `json:"id"`
	OK              bool          `json:"ok"`
	Value           any           `json:"value,omitempty"`
	Error           *adapterError `json:"error,omitempty"`
}

type adapterError struct {
	Kind    string `json:"kind"`
	Message string `json:"message"`
}

func main() {
	var input request
	if err := json.NewDecoder(bufio.NewReader(os.Stdin)).Decode(&input); err != nil {
		write(response{
			ContractVersion: 2,
			OK:              false,
			Error:           &adapterError{Kind: "adapter", Message: err.Error()},
		})
		return
	}
	value, err := dispatch(input)
	if err != nil {
		write(response{
			ContractVersion: 2,
			ID:              input.ID,
			OK:              false,
			Error:           &adapterError{Kind: classify(err), Message: err.Error()},
		})
		return
	}
	write(response{ContractVersion: 2, ID: input.ID, OK: true, Value: value})
}

func write(value response) {
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(value); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
}

func classify(err error) string {
	var resource *bree.ResourceError
	var protocol *bree.ProtocolError
	var transport *bree.TransportError
	switch {
	case errors.As(err, &resource):
		return "resource"
	case errors.As(err, &protocol):
		return "protocol"
	case errors.As(err, &transport):
		return "transport"
	default:
		return "adapter"
	}
}

func dispatch(input request) (any, error) {
	if input.Op == "redaction" {
		return redaction()
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	client, err := bree.NewClient(ctx, bree.ClientOptions{
		SocketPath: input.SocketPath,
		Timeout:    15 * time.Second,
	})
	if err != nil {
		return nil, err
	}
	defer client.Close(context.Background()) //nolint:errcheck
	session, workspace, err := handles(client, input.Constants)
	if err != nil {
		return nil, err
	}

	switch input.Op {
	case "read":
		result, err := session.Ping(ctx, bree.SessionPingOptions{})
		if err != nil {
			return nil, err
		}
		return map[string]any{
			"alive":  result.Alive,
			"cursor": cursorValue(&result.Cursor),
		}, nil
	case "mutation-replay":
		options, err := renameOptions(input.Constants)
		if err != nil {
			return nil, err
		}
		first, err := workspace.Rename(ctx, options)
		if err != nil {
			return nil, err
		}
		second, err := workspace.Rename(ctx, options)
		if err != nil {
			return nil, err
		}
		firstValue, err := mutationValue(first)
		if err != nil {
			return nil, err
		}
		secondValue, err := mutationValue(second)
		if err != nil {
			return nil, err
		}
		return map[string]any{
			"first":  firstValue,
			"second": secondValue,
		}, nil
	case "mutation-error":
		options, err := renameOptions(input.Constants)
		if err != nil {
			return nil, err
		}
		_, err = workspace.Rename(ctx, options)
		if err == nil {
			return nil, errors.New("mutation unexpectedly succeeded")
		}
		var resource *bree.ResourceError
		if !errors.As(err, &resource) {
			return nil, err
		}
		var details any
		decoder := json.NewDecoder(strings.NewReader(string(resource.Details)))
		decoder.UseNumber()
		if err := decoder.Decode(&details); err != nil {
			return nil, err
		}
		return map[string]any{
			"code":      resource.Code,
			"message":   resource.Message,
			"details":   normalize(details),
			"retryable": resource.Retryable,
		}, nil
	case "creation-resolve":
		resolution, err := session.ResolveCreation(
			ctx,
			input.Constants.CorrelationKey,
			bree.SessionCreationResolveOptions{},
		)
		if err != nil {
			return nil, err
		}
		return creationResolutionValue(resolution), nil
	case "creation-conflict":
		name := input.Constants.Name
		_, err := session.CreateWorkspace(ctx, bree.WorkspaceCreateOptions{
			MutationOptions: bree.MutationOptions{
				IdempotencyKey: input.Constants.IdempotencyKey,
				CorrelationKey: input.Constants.CorrelationKey,
			},
			Name:           &name,
			InitialContent: "empty",
		})
		if err == nil {
			return nil, errors.New("creation conflict unexpectedly succeeded")
		}
		return resourceErrorValue(err)
	case "terminal-wait-exit":
		timeout, err := decimalPointer(input.TimeoutMS)
		if err != nil {
			return nil, err
		}
		terminalID, err := bree.ParseTerminalID(input.Constants.Terminal)
		if err != nil {
			return nil, err
		}
		value, err := session.Terminal(bree.SelectID(terminalID)).WaitExit(
			ctx,
			bree.TerminalWaitExitOptions{TimeoutMS: timeout},
		)
		if err != nil {
			return nil, err
		}
		return terminalWaitExitValue(value)
	case "stream-unknown":
		stream, err := session.Events(ctx, bree.SessionEventsOptions{})
		if err != nil {
			return nil, err
		}
		item, err := stream.Recv(ctx)
		if err != nil {
			return nil, err
		}
		end, err := receiveEnd(ctx, stream)
		if err != nil {
			return nil, err
		}
		return map[string]any{
			"sequence": item.Sequence.String(),
			"cursor":   cursorValue(item.Cursor),
			"kind":     item.Value.Kind,
			"raw":      normalize(item.Value.Raw),
			"end":      end,
		}, nil
	case "stream-cancel":
		stream, err := session.Events(ctx, bree.SessionEventsOptions{})
		if err != nil {
			return nil, err
		}
		if err := stream.Cancel(ctx); err != nil {
			return nil, err
		}
		if err := stream.Cancel(ctx); err != nil {
			return nil, err
		}
		items := 0
		for {
			_, err := stream.Recv(ctx)
			if err == nil {
				items++
				continue
			}
			var observed *bree.StreamEndError
			if !errors.As(err, &observed) && !errors.Is(err, bree.ErrClosed) {
				return nil, err
			}
			break
		}
		terminal := stream.End()
		if terminal == nil {
			return nil, errors.New("cancel omitted terminal stream end")
		}
		return map[string]any{
			"end":                terminal.Reason,
			"items_after_cancel": items,
			"cancel_calls":       2,
		}, nil
	case "stream-overflow":
		first, err := session.Events(ctx, bree.SessionEventsOptions{})
		if err != nil {
			return nil, err
		}
		firstEnd, err := receiveEnd(ctx, first)
		if err != nil {
			return nil, err
		}
		second, err := session.Events(ctx, bree.SessionEventsOptions{})
		if err != nil {
			return nil, err
		}
		secondItem, err := second.Recv(ctx)
		if err != nil {
			return nil, err
		}
		if _, err := receiveEnd(ctx, second); err != nil {
			return nil, err
		}
		result, err := session.Ping(ctx, bree.SessionPingOptions{})
		if err != nil {
			return nil, err
		}
		return map[string]any{
			"first_end":     firstEnd,
			"second_kind":   secondItem.Value.Kind,
			"control_alive": result.Alive,
		}, nil
	case "live-setup":
		return liveSetup(ctx, client, input)
	case "live-creation-exit":
		return liveCreationExit(ctx, client, input)
	case "live-exit-restart":
		return liveExitRestart(ctx, client, input)
	case "live-restart":
		return liveRestart(ctx, client, input)
	default:
		return nil, fmt.Errorf("unknown adapter operation %q", input.Op)
	}
}

func handles(
	client *bree.Client,
	values constants,
) (*bree.Session, *bree.Workspace, error) {
	sessionID, err := bree.ParseSessionID(values.Session)
	if err != nil {
		return nil, nil, err
	}
	workspaceID, err := bree.ParseWorkspaceID(values.Workspace)
	if err != nil {
		return nil, nil, err
	}
	session := client.Machine(bree.SelectCurrent[bree.MachineID]()).
		Session(bree.SelectID(sessionID))
	return session, session.Workspace(bree.SelectID(workspaceID)), nil
}

func renameOptions(values constants) (bree.WorkspaceRenameOptions, error) {
	revision, err := strconv.ParseUint(values.Revision, 10, 64)
	if err != nil {
		return bree.WorkspaceRenameOptions{}, err
	}
	decimal := bree.Decimal(revision)
	return bree.WorkspaceRenameOptions{
		MutationOptions: bree.MutationOptions{
			IdempotencyKey:   values.IdempotencyKey,
			ExpectedRevision: &decimal,
		},
		Name: values.Name,
	}, nil
}

func mutationValue(
	result bree.MutationResult[*bree.Workspace],
) (map[string]any, error) {
	snapshot, ok := result.Value.Cached()
	if !ok {
		return nil, errors.New("workspace mutation result handle omitted its snapshot")
	}
	return map[string]any{
		"workspace_id": snapshot.ID,
		"name":         snapshot.Name,
		"generation":   result.Generation,
		"revision":     result.Revision.String(),
		"replayed":     result.Replayed,
	}, nil
}

func resourceErrorValue(err error) (map[string]any, error) {
	var resource *bree.ResourceError
	if !errors.As(err, &resource) {
		return nil, err
	}
	var details any
	decoder := json.NewDecoder(strings.NewReader(string(resource.Details)))
	decoder.UseNumber()
	if err := decoder.Decode(&details); err != nil {
		return nil, err
	}
	return map[string]any{
		"code":      resource.Code,
		"message":   resource.Message,
		"details":   normalize(details),
		"retryable": resource.Retryable,
	}, nil
}

func createdPathValue(path bree.CreatedPath) map[string]any {
	result := map[string]any{
		"kind":         path.Kind,
		"workspace_id": string(path.Workspace),
	}
	if path.Kind == "workspace" {
		return result
	}
	result["screen_id"] = string(path.Screen)
	result["pane_id"] = string(path.Pane)
	result["tab_id"] = string(path.Tab)
	switch path.Kind {
	case "terminal":
		result["terminal_id"] = string(path.Terminal)
	case "browser":
		result["browser_id"] = string(path.Browser)
	}
	return result
}

func creationResolutionValue(value bree.CreationResolution) map[string]any {
	result := map[string]any{
		"correlation_key": value.CorrelationKey,
		"state":           value.State,
		"recovery":        value.Recovery,
	}
	if value.Operation != nil {
		result["operation"] = *value.Operation
	}
	if value.IdempotencyKey != nil {
		result["idempotency_key"] = *value.IdempotencyKey
	}
	if value.CreatedPath != nil {
		result["created_path"] = createdPathValue(*value.CreatedPath)
	}
	if value.Generation != nil {
		result["generation"] = *value.Generation
	}
	if value.Revision != nil {
		result["revision"] = value.Revision.String()
	}
	return result
}

func terminalExitOutcomeValue(
	outcome bree.TerminalExitOutcome,
) (map[string]any, error) {
	switch value := outcome.(type) {
	case bree.TerminalExitCode:
		return map[string]any{"kind": value.Kind, "code": value.Code}, nil
	case bree.TerminalExitSignal:
		return map[string]any{
			"kind": value.Kind, "signal": value.Signal,
			"core_dumped": value.CoreDumped,
		}, nil
	case bree.TerminalExitUnknown:
		return map[string]any{"kind": value.Kind, "reason": value.Reason}, nil
	default:
		return nil, fmt.Errorf("unsupported terminal exit outcome %T", outcome)
	}
}

func terminalWaitExitValue(
	result bree.TerminalWaitExitResult,
) (map[string]any, error) {
	switch value := result.(type) {
	case bree.TerminalWaitExitPending:
		return map[string]any{
			"state":       value.State,
			"terminal_id": string(value.TerminalID),
			"lifecycle":   value.Lifecycle,
			"revision":    value.Revision.String(),
		}, nil
	case bree.TerminalWaitExitExited:
		outcome, err := terminalExitOutcomeValue(value.Outcome)
		if err != nil {
			return nil, err
		}
		return map[string]any{
			"state":       value.State,
			"terminal_id": string(value.TerminalID),
			"lifecycle":   value.Lifecycle,
			"outcome":     outcome,
			"exited_at":   value.ExitedAt.String(),
			"revision":    value.Revision.String(),
		}, nil
	default:
		return nil, fmt.Errorf("unsupported terminal wait exit result %T", result)
	}
}

func decimalPointer(value string) (*bree.Decimal, error) {
	parsed, err := strconv.ParseUint(value, 10, 64)
	if err != nil {
		return nil, err
	}
	decimal := bree.Decimal(parsed)
	return &decimal, nil
}

func cursorValue(cursor *bree.Cursor) any {
	if cursor == nil {
		return nil
	}
	return map[string]any{
		"generation": cursor.Generation,
		"revision":   cursor.Revision.String(),
	}
}

func receiveEnd(
	ctx context.Context,
	stream *bree.Stream[bree.SessionEvent],
) (string, error) {
	for {
		_, err := stream.Recv(ctx)
		if err == nil {
			continue
		}
		var terminal *bree.StreamEndError
		if errors.As(err, &terminal) {
			return terminal.Reason, nil
		}
		return "", err
	}
}

func normalize(value any) any {
	switch typed := value.(type) {
	case map[string]any:
		result := make(map[string]any, len(typed))
		for key, item := range typed {
			result[key] = normalize(item)
		}
		return result
	case []any:
		result := make([]any, len(typed))
		for index, item := range typed {
			result[index] = normalize(item)
		}
		return result
	case json.Number:
		return typed.String()
	default:
		return value
	}
}

func redaction() (any, error) {
	const secret = "provider://conformance-secret"
	const token = "renderer-conformance-secret"
	specifier := bree.NewSecret(secret)
	terminalID, err := bree.ParseTerminalID(
		"term_66666666666666666666666666666666",
	)
	if err != nil {
		return nil, err
	}
	grant := bree.RendererGrant{
		Endpoint:   "unix:///tmp/renderer",
		TerminalID: terminalID,
		Token:      bree.NewSecret(token),
		Rights:     []string{"render"},
		TTLMS:      1000,
	}
	return map[string]any{
		"specifier_redacted":      !strings.Contains(fmt.Sprintf("%v %#v", specifier, specifier), secret),
		"renderer_token_redacted": !strings.Contains(fmt.Sprintf("%v %#v", grant, grant), token),
	}, nil
}

func liveSession(client *bree.Client) *bree.Session {
	return client.Machine(bree.SelectCurrent[bree.MachineID]()).
		Session(bree.SelectCurrent[bree.SessionID]())
}

func workspaceRows(
	ctx context.Context,
	session *bree.Session,
) (map[string]string, error) {
	values, err := session.ListWorkspaces(ctx, bree.WorkspaceListOptions{})
	if err != nil {
		return nil, err
	}
	rows := make(map[string]string, len(values))
	for index := range values {
		snapshot, ok := values[index].Cached()
		if !ok {
			snapshot, err = values[index].Refresh(ctx)
			if err != nil {
				return nil, err
			}
		}
		rows[string(snapshot.ID)] = snapshot.Name
	}
	return rows, nil
}

func createEmptyWorkspace(
	ctx context.Context,
	session *bree.Session,
	name string,
	key string,
) (bree.WorkspaceID, error) {
	created, err := session.CreateWorkspace(ctx, bree.WorkspaceCreateOptions{
		MutationOptions: bree.MutationOptions{IdempotencyKey: key},
		Name:            &name,
		InitialContent:  "empty",
	})
	if err != nil {
		return "", err
	}
	if created.Value.Workspace == "" {
		return "", errors.New("workspace.create omitted workspace id")
	}
	return created.Value.Workspace, nil
}

func liveSetup(ctx context.Context, client *bree.Client, input request) (any, error) {
	session := liveSession(client)
	ping, err := session.Ping(ctx, bree.SessionPingOptions{})
	if err != nil {
		return nil, err
	}
	baseName := input.WorkspaceName
	keyPrefix := input.KeyPrefix
	stableID, err := createEmptyWorkspace(
		ctx,
		session,
		baseName,
		keyPrefix+"-stable-create",
	)
	if err != nil {
		return nil, err
	}
	stable := session.Workspace(bree.SelectID(stableID))
	stableRenamedName := baseName + "-renamed"
	renamed, err := stable.Rename(ctx, bree.WorkspaceRenameOptions{
		MutationOptions: bree.MutationOptions{
			IdempotencyKey: keyPrefix + "-stable-rename",
		},
		Name: stableRenamedName,
	})
	if err != nil {
		return nil, err
	}

	duplicateName := baseName + "-duplicate"
	duplicateIDs := make([]bree.WorkspaceID, 0, 2)
	for _, suffix := range []string{"a", "b"} {
		identifier, err := createEmptyWorkspace(
			ctx,
			session,
			duplicateName,
			keyPrefix+"-duplicate-"+suffix,
		)
		if err != nil {
			return nil, err
		}
		duplicateIDs = append(duplicateIDs, identifier)
	}

	_, ambiguityErr := session.Workspace(
		bree.SelectName[bree.WorkspaceID](duplicateName),
	).Rename(ctx, bree.WorkspaceRenameOptions{
		MutationOptions: bree.MutationOptions{
			IdempotencyKey: keyPrefix + "-ambiguous-rename",
		},
		Name: baseName + "-must-not-apply",
	})
	if ambiguityErr == nil {
		return nil, errors.New("duplicate workspace selector unexpectedly mutated")
	}
	var resource *bree.ResourceError
	if !errors.As(ambiguityErr, &resource) {
		return nil, ambiguityErr
	}
	var details struct {
		Candidates []string `json:"candidates"`
	}
	if err := json.Unmarshal(resource.Details, &details); err != nil {
		return nil, err
	}
	expectedCandidates := map[string]bool{
		string(duplicateIDs[0]): true,
		string(duplicateIDs[1]): true,
	}
	preservedCandidates := len(details.Candidates) == len(duplicateIDs)
	for _, candidate := range details.Candidates {
		preservedCandidates = preservedCandidates && expectedCandidates[candidate]
	}

	rows, err := workspaceRows(ctx, session)
	if err != nil {
		return nil, err
	}
	noMutation := true
	for _, identifier := range duplicateIDs {
		noMutation = noMutation && rows[string(identifier)] == duplicateName
	}
	for _, name := range rows {
		noMutation = noMutation && name != baseName+"-must-not-apply"
	}
	return map[string]any{
		"pinged":                             ping.Alive,
		"stable_id":                          stableID,
		"stable_renamed":                     workspaceHasName(renamed.Value, stableRenamedName),
		"duplicate_ids":                      duplicateIDs,
		"ambiguity_code":                     resource.Code,
		"ambiguity_preserved_all_candidates": preservedCandidates,
		"no_mutation":                        noMutation,
	}, nil
}

func liveCreationExit(
	ctx context.Context,
	client *bree.Client,
	input request,
) (any, error) {
	session := liveSession(client)
	stableID, err := bree.ParseWorkspaceID(input.ExpectedStableID)
	if err != nil {
		return nil, err
	}
	workspace := session.Workspace(bree.SelectID(stableID))
	screenCreated, err := workspace.CreateScreen(ctx, bree.ScreenCreateOptions{
		MutationOptions: bree.MutationOptions{
			IdempotencyKey: input.KeyPrefix + "-runtime-screen",
		},
	})
	if err != nil {
		return nil, err
	}
	if screenCreated.Value.Kind != "terminal" ||
		screenCreated.Value.Screen == "" || screenCreated.Value.Pane == "" {
		return nil, errors.New("screen.create omitted its terminal pane path")
	}
	pane := workspace.Screen(bree.SelectID(screenCreated.Value.Screen)).
		Pane(bree.SelectID(screenCreated.Value.Pane))
	correlationKey := input.KeyPrefix + "-terminal-correlation"
	runResult, err := pane.Run(ctx, bree.PaneRunOptions{
		MutationOptions: bree.MutationOptions{
			IdempotencyKey: input.KeyPrefix + "-terminal-run",
			CorrelationKey: correlationKey,
		},
		Command: bree.Shell(input.ExitShell),
	})
	if err != nil {
		return nil, err
	}
	if runResult.Value.Kind != "terminal" || runResult.Value.Terminal == "" {
		return nil, errors.New("pane.run omitted its terminal path")
	}
	terminal := session.Terminal(bree.SelectID(runResult.Value.Terminal))
	pendingTimeout, err := decimalPointer(input.PendingTimeoutMS)
	if err != nil {
		return nil, err
	}
	pendingResult, err := terminal.WaitExit(ctx, bree.TerminalWaitExitOptions{
		TimeoutMS: pendingTimeout,
	})
	if err != nil {
		return nil, err
	}
	pending, err := terminalWaitExitValue(pendingResult)
	if err != nil {
		return nil, err
	}
	resolution, err := session.ResolveCreation(
		ctx,
		correlationKey,
		bree.SessionCreationResolveOptions{},
	)
	if err != nil {
		return nil, err
	}
	if resolution.CreatedPath == nil || *resolution.CreatedPath != runResult.Value {
		return nil, errors.New("creation resolution returned a different terminal path")
	}
	creation := creationResolutionValue(resolution)
	exitTimeout, err := decimalPointer(input.ExitTimeoutMS)
	if err != nil {
		return nil, err
	}
	exitResult, err := terminal.WaitExit(ctx, bree.TerminalWaitExitOptions{
		TimeoutMS: exitTimeout,
	})
	if err != nil {
		return nil, err
	}
	exited, err := terminalWaitExitValue(exitResult)
	if err != nil {
		return nil, err
	}
	outcome, ok := exited["outcome"].(map[string]any)
	if !ok {
		return nil, errors.New("terminal did not return an exited outcome")
	}
	return map[string]any{
		"correlation_key":     correlationKey,
		"created_path":        createdPathValue(runResult.Value),
		"pending_terminal_id": pending["terminal_id"],
		"pending_state":       pending["state"],
		"pending_lifecycle":   pending["lifecycle"],
		"creation_state":      creation["state"],
		"creation_recovery":   creation["recovery"],
		"creation_generation": creation["generation"],
		"creation_revision":   creation["revision"],
		"exit_state":          exited["state"],
		"exit_terminal_id":    exited["terminal_id"],
		"exit_lifecycle":      exited["lifecycle"],
		"exit_kind":           outcome["kind"],
		"exit_code":           outcome["code"],
		"exited_at":           exited["exited_at"],
		"exit_revision":       exited["revision"],
	}, nil
}

func liveExitRestart(
	ctx context.Context,
	client *bree.Client,
	input request,
) (any, error) {
	session := liveSession(client)
	resolution, err := session.ResolveCreation(
		ctx,
		input.ExpectedCorrelationKey,
		bree.SessionCreationResolveOptions{},
	)
	if err != nil {
		return nil, err
	}
	terminalID, err := bree.ParseTerminalID(input.ExpectedCreatedPath.Terminal)
	if err != nil {
		return nil, err
	}
	timeout, err := decimalPointer(input.ExitTimeoutMS)
	if err != nil {
		return nil, err
	}
	exitResult, err := session.Terminal(bree.SelectID(terminalID)).WaitExit(
		ctx,
		bree.TerminalWaitExitOptions{TimeoutMS: timeout},
	)
	if err != nil {
		return nil, err
	}
	exited, err := terminalWaitExitValue(exitResult)
	if err != nil {
		return nil, err
	}
	outcome, ok := exited["outcome"].(map[string]any)
	if !ok {
		return nil, errors.New("terminal did not return a durable exit outcome")
	}
	creation := creationResolutionValue(resolution)
	return map[string]any{
		"correlation_key":     creation["correlation_key"],
		"created_path":        creation["created_path"],
		"creation_state":      creation["state"],
		"creation_recovery":   creation["recovery"],
		"creation_generation": creation["generation"],
		"creation_revision":   creation["revision"],
		"exit_state":          exited["state"],
		"exit_terminal_id":    exited["terminal_id"],
		"exit_lifecycle":      exited["lifecycle"],
		"exit_kind":           outcome["kind"],
		"exit_code":           outcome["code"],
		"exited_at":           exited["exited_at"],
		"exit_revision":       exited["revision"],
	}, nil
}

func liveRestart(ctx context.Context, client *bree.Client, input request) (any, error) {
	if len(input.ExpectedDuplicateIDs) != 2 {
		return nil, errors.New("expected_duplicate_ids must contain two ids")
	}
	stableID, err := bree.ParseWorkspaceID(input.ExpectedStableID)
	if err != nil {
		return nil, err
	}
	duplicateIDs := make([]bree.WorkspaceID, 0, 2)
	for _, raw := range input.ExpectedDuplicateIDs {
		identifier, err := bree.ParseWorkspaceID(raw)
		if err != nil {
			return nil, err
		}
		duplicateIDs = append(duplicateIDs, identifier)
	}
	session := liveSession(client)
	rows, err := workspaceRows(ctx, session)
	if err != nil {
		return nil, err
	}
	expectedIDs := []bree.WorkspaceID{stableID, duplicateIDs[0], duplicateIDs[1]}
	sameIDs := true
	for _, identifier := range expectedIDs {
		_, found := rows[string(identifier)]
		sameIDs = sameIDs && found
	}
	stableNamePreserved :=
		rows[string(stableID)] == input.WorkspaceName+"-renamed"
	duplicatesPreserved := true
	for _, identifier := range duplicateIDs {
		duplicatesPreserved = duplicatesPreserved &&
			rows[string(identifier)] == input.WorkspaceName+"-duplicate"
	}

	closeTargets := []struct {
		ID     bree.WorkspaceID
		Suffix string
	}{
		{stableID, "stable"},
		{duplicateIDs[0], "a"},
		{duplicateIDs[1], "b"},
	}
	for _, target := range closeTargets {
		_, err := session.Workspace(bree.SelectID(target.ID)).Close(
			ctx,
			bree.WorkspaceCloseOptions{
				MutationOptions: bree.MutationOptions{
					IdempotencyKey: input.KeyPrefix + "-close-" + target.Suffix,
				},
			},
		)
		if err != nil {
			return nil, err
		}
	}
	remaining, err := workspaceRows(ctx, session)
	if err != nil {
		return nil, err
	}
	disappeared := true
	for _, identifier := range expectedIDs {
		_, found := remaining[string(identifier)]
		disappeared = disappeared && !found
	}
	return map[string]any{
		"same_ids":              sameIDs,
		"stable_name_preserved": stableNamePreserved,
		"duplicates_preserved":  duplicatesPreserved,
		"closed":                true,
		"disappeared":           disappeared,
	}, nil
}

func liveFlow(ctx context.Context, client *bree.Client, input request) (any, error) {
	session := client.Machine(bree.SelectCurrent[bree.MachineID]()).
		Session(bree.SelectCurrent[bree.SessionID]())
	ping, err := session.Ping(ctx, bree.SessionPingOptions{})
	if err != nil {
		return nil, err
	}
	name := input.WorkspaceName
	created, err := session.CreateWorkspace(ctx, bree.WorkspaceCreateOptions{
		MutationOptions: bree.MutationOptions{IdempotencyKey: "live-create"},
		Name:            &name,
		InitialContent:  "empty",
	})
	if err != nil {
		return nil, err
	}
	workspace := session.Workspace(bree.SelectID(created.Value.Workspace))
	renamedName := name + "-renamed"
	renamed, err := workspace.Rename(ctx, bree.WorkspaceRenameOptions{
		MutationOptions: bree.MutationOptions{IdempotencyKey: "live-rename"},
		Name:            renamedName,
	})
	if err != nil {
		return nil, err
	}
	listedValues, err := session.ListWorkspaces(ctx, bree.WorkspaceListOptions{})
	if err != nil {
		return nil, err
	}
	listed := false
	for index := range listedValues {
		if snapshot, ok := listedValues[index].Cached(); ok &&
			snapshot.ID == created.Value.Workspace {
			listed = true
		}
	}
	if _, err := workspace.Close(ctx, bree.WorkspaceCloseOptions{
		MutationOptions: bree.MutationOptions{IdempotencyKey: "live-close"},
	}); err != nil {
		return nil, err
	}
	remaining, err := session.ListWorkspaces(ctx, bree.WorkspaceListOptions{})
	if err != nil {
		return nil, err
	}
	disappeared := true
	for index := range remaining {
		if snapshot, ok := remaining[index].Cached(); ok &&
			snapshot.ID == created.Value.Workspace {
			disappeared = false
		}
	}
	return map[string]any{
		"pinged":      ping.Alive,
		"created":     created.Value.Workspace != "",
		"renamed":     workspaceHasName(renamed.Value, renamedName),
		"listed":      listed,
		"closed":      true,
		"disappeared": disappeared,
	}, nil
}

func workspaceHasName(workspace *bree.Workspace, expected string) bool {
	snapshot, ok := workspace.Cached()
	return ok && snapshot.Name == expected
}
