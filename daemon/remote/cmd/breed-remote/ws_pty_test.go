package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/creack/pty"
)

type doneObservedContext struct {
	context.Context
	observed chan<- struct{}
}

func (c doneObservedContext) Done() <-chan struct{} {
	select {
	case c.observed <- struct{}{}:
	default:
	}
	return c.Context.Done()
}

type cancelAfterFirstErrContext struct {
	context.Context
	cancel context.CancelFunc
	calls  atomic.Int32
}

func (c *cancelAfterFirstErrContext) Err() error {
	if err := c.Context.Err(); err != nil {
		return err
	}
	if c.calls.Add(1) == 1 {
		c.cancel()
	}
	return nil
}

type gatedDoneContext struct {
	context.Context
	observed chan<- struct{}
	release  <-chan struct{}
}

func (c gatedDoneContext) Done() <-chan struct{} {
	select {
	case c.observed <- struct{}{}:
	default:
	}
	<-c.release
	return c.Context.Done()
}

// TestAttachRPCSurfacesPTYAllocationFailure pins the contract that a remote PTY
// allocation failure (e.g. a hardened devpts mounted ptmxmode=000 where
// /dev/ptmx cannot be opened) is reported loudly: the error returned to the
// client names the failing device and explains the devpts cause, and the daemon
// records a safe failure category instead of leaving a 0-byte log. This is the
// regression for https://github.com/ecyx00/bree/issues/5185, where the failure
// collapsed into a generic "remote PTY attach failed" with an empty daemon log.
func TestAttachRPCSurfacesPTYAllocationFailure(t *testing.T) {
	stderr := newNotifyingBuffer()
	hub := newWebSocketPTYHub(wsPTYServerConfig{Shell: "/bin/sh"}, stderr)
	t.Cleanup(hub.closeAll)

	denied := &os.PathError{Op: "open", Path: "/dev/ptmx", Err: syscall.EACCES}
	hub.openPTY = func() (*os.File, *os.File, error) {
		return nil, nil, denied
	}

	_, _, _, err := hub.attachRPC(context.Background(), "sess-1", "att-1", 80, 24, "", "", false, false)
	if err == nil {
		t.Fatalf("expected attachRPC to fail when PTY allocation is denied")
	}

	msg := err.Error()
	lowered := strings.ToLower(msg)
	// Pin the stable marker the Swift clients key their passthrough off of: a
	// daemon wording change that dropped it would silently break client-side
	// preservation of this diagnostic without failing any other assertion. Match
	// case-insensitively, exactly as Sources/Workspace.swift does.
	if !strings.Contains(lowered, "could not allocate a remote pty") {
		t.Fatalf("error must preserve the stable PTY-allocation marker the clients key off: %q", msg)
	}
	if !strings.Contains(msg, "/dev/ptmx") {
		t.Fatalf("error should name the device that could not be opened: %q", msg)
	}
	// The EACCES remediation hint is appended for any permission-denied failure
	// independent of /proc/self/mountinfo, so these assertions hold even in a
	// container/sandbox without a real devpts mount (describeDevPTS may add
	// nothing there). Key off the hint, not the optional mount summary.
	if !strings.Contains(lowered, "ptmxmode") || !strings.Contains(lowered, "remount") {
		t.Fatalf("error should explain the hardened devpts cause and remediation: %q", msg)
	}

	if stderr.String() == "" {
		t.Fatalf("PTY allocation failure must be logged to the daemon log, not swallowed")
	}
	if !strings.Contains(stderr.String(), "event=pty_start_fault") ||
		!strings.Contains(stderr.String(), `error_category="permission_denied"`) {
		t.Fatalf("daemon log should classify the allocation failure: %q", stderr.String())
	}
	if strings.Contains(stderr.String(), denied.Error()) {
		t.Fatalf("daemon log should not persist the raw allocation failure: %q", stderr.String())
	}
}

func TestAttachRPCStalledSessionStartDoesNotBlockHealthyReattach(t *testing.T) {
	hub := newWebSocketPTYHub(wsPTYServerConfig{Shell: "/bin/sh"}, io.Discard)
	t.Cleanup(hub.closeAll)

	const healthySessionID = "healthy-session"
	if _, _, _, err := hub.attachRPC(
		context.Background(),
		healthySessionID,
		"initial-attachment",
		80,
		24,
		"sleep 30",
		"",
		false,
		false,
	); err != nil {
		t.Fatalf("start healthy session: %v", err)
	}

	openPTY := hub.openPTY
	startEntered := make(chan struct{})
	releaseStart := make(chan struct{})
	var startCount atomic.Int32
	hub.openPTY = func() (*os.File, *os.File, error) {
		if startCount.Add(1) == 1 {
			close(startEntered)
			<-releaseStart
		}
		return openPTY()
	}

	stalledResult := make(chan error, 1)
	go func() {
		_, _, _, err := hub.attachRPC(
			context.Background(),
			"stalled-session",
			"stalled-attachment",
			80,
			24,
			"sleep 30",
			"",
			false,
			false,
		)
		stalledResult <- err
	}()

	select {
	case <-startEntered:
	case <-time.After(5 * time.Second):
		t.Fatal("stalled session never attempted PTY allocation")
	}

	healthyResult := make(chan error, 1)
	go func() {
		_, _, _, err := hub.attachRPC(
			context.Background(),
			healthySessionID,
			"reattachment",
			80,
			24,
			"",
			"",
			true,
			false,
		)
		healthyResult <- err
	}()

	select {
	case err := <-healthyResult:
		if err != nil {
			close(releaseStart)
			<-stalledResult
			t.Fatalf("reattach healthy session: %v", err)
		}
	case <-time.After(time.Second):
		close(releaseStart)
		<-stalledResult
		<-healthyResult
		t.Fatal("healthy reattach blocked behind another session's stalled PTY allocation")
	}

	independentResult := make(chan error, 1)
	go func() {
		_, _, _, err := hub.attachRPC(
			context.Background(),
			"independent-session",
			"independent-attachment",
			80,
			24,
			"sleep 30",
			"",
			false,
			false,
		)
		independentResult <- err
	}()
	select {
	case err := <-independentResult:
		if err != nil {
			close(releaseStart)
			<-stalledResult
			t.Fatalf("start independent session: %v", err)
		}
	case <-time.After(time.Second):
		close(releaseStart)
		<-stalledResult
		<-independentResult
		t.Fatal("independent session start blocked behind another session's stalled PTY allocation")
	}

	close(releaseStart)
	if err := <-stalledResult; err != nil {
		t.Fatalf("finish formerly stalled session start: %v", err)
	}
}

func TestAttachRPCConcurrentSameSessionStartsOnce(t *testing.T) {
	hub := newWebSocketPTYHub(wsPTYServerConfig{Shell: "/bin/sh"}, io.Discard)
	t.Cleanup(hub.closeAll)

	openPTY := hub.openPTY
	startEntered := make(chan struct{}, 2)
	releaseStart := make(chan struct{})
	var startCount atomic.Int32
	hub.openPTY = func() (*os.File, *os.File, error) {
		startCount.Add(1)
		startEntered <- struct{}{}
		<-releaseStart
		return openPTY()
	}

	attach := func(ctx context.Context, attachmentID string) <-chan error {
		result := make(chan error, 1)
		go func() {
			_, _, _, err := hub.attachRPC(
				ctx,
				"shared-session",
				attachmentID,
				80,
				24,
				"sleep 30",
				"",
				false,
				false,
			)
			result <- err
		}()
		return result
	}

	firstResult := attach(context.Background(), "first-attachment")
	select {
	case <-startEntered:
	case <-time.After(5 * time.Second):
		t.Fatal("first attach never attempted PTY allocation")
	}

	secondWaiting := make(chan struct{}, 1)
	secondResult := attach(
		doneObservedContext{Context: context.Background(), observed: secondWaiting},
		"second-attachment",
	)
	select {
	case <-secondWaiting:
	case <-time.After(time.Second):
		close(releaseStart)
		<-firstResult
		<-secondResult
		t.Fatal("second attach did not join the in-flight session start")
	}
	if got := startCount.Load(); got != 1 {
		close(releaseStart)
		<-firstResult
		<-secondResult
		t.Fatalf("PTY start count before release = %d, want 1", got)
	}
	close(releaseStart)

	if err := <-firstResult; err != nil {
		t.Fatalf("first attach: %v", err)
	}
	if err := <-secondResult; err != nil {
		t.Fatalf("second attach: %v", err)
	}
	if got := startCount.Load(); got != 1 {
		t.Fatalf("PTY start count = %d, want 1 for concurrent attaches to one session", got)
	}

	hub.mu.Lock()
	session := hub.sessions[persistentPTYSessionKey("shared-session")]
	pendingStarts := len(hub.startingSessions)
	attachmentCount := 0
	if session != nil {
		attachmentCount = len(session.attachments)
	}
	hub.mu.Unlock()
	if pendingStarts != 0 {
		t.Fatalf("pending session starts = %d, want 0 after successful start", pendingStarts)
	}
	if attachmentCount != 2 {
		t.Fatalf("shared session attachments = %d, want 2", attachmentCount)
	}
}

func TestAttachRPCSharedStartSurvivesOwnerCancellation(t *testing.T) {
	hub := newWebSocketPTYHub(wsPTYServerConfig{Shell: "/bin/sh"}, io.Discard)
	t.Cleanup(hub.closeAll)

	openPTY := hub.openPTY
	startEntered := make(chan struct{})
	releaseStart := make(chan struct{})
	hub.openPTY = func() (*os.File, *os.File, error) {
		close(startEntered)
		<-releaseStart
		return openPTY()
	}

	ownerCtx, cancelOwner := context.WithCancel(context.Background())
	ownerResult := make(chan error, 1)
	go func() {
		_, _, _, err := hub.attachRPC(
			ownerCtx,
			"owner-canceled-session",
			"owner",
			80,
			24,
			"sleep 30",
			"",
			false,
			false,
		)
		ownerResult <- err
	}()
	select {
	case <-startEntered:
	case <-time.After(5 * time.Second):
		t.Fatal("start owner never attempted PTY allocation")
	}

	waiterJoined := make(chan struct{}, 1)
	waiterResult := make(chan error, 1)
	go func() {
		_, _, _, err := hub.attachRPC(
			doneObservedContext{Context: context.Background(), observed: waiterJoined},
			"owner-canceled-session",
			"waiter",
			80,
			24,
			"sleep 30",
			"",
			false,
			false,
		)
		waiterResult <- err
	}()
	select {
	case <-waiterJoined:
	case <-time.After(time.Second):
		close(releaseStart)
		t.Fatal("live waiter did not join the owner's in-flight start")
	}

	cancelOwner()
	close(releaseStart)
	if err := <-ownerResult; !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled start owner error = %v, want context canceled", err)
	}
	if err := <-waiterResult; err != nil {
		t.Fatalf("live waiter failed after start owner cancellation: %v", err)
	}

	hub.mu.Lock()
	session := hub.sessions[persistentPTYSessionKey("owner-canceled-session")]
	attachmentCount := 0
	if session != nil {
		attachmentCount = len(session.attachments)
	}
	hub.mu.Unlock()
	if attachmentCount != 1 {
		t.Fatalf("shared session attachments = %d, want live waiter only", attachmentCount)
	}
}

func TestAttachRPCSharedStartDropsWaitersCanceledBeforePublication(t *testing.T) {
	hub := newWebSocketPTYHub(wsPTYServerConfig{Shell: "/bin/sh"}, io.Discard)
	t.Cleanup(hub.closeAll)

	openPTY := hub.openPTY
	startEntered := make(chan struct{})
	releaseStart := make(chan struct{})
	hub.openPTY = func() (*os.File, *os.File, error) {
		close(startEntered)
		<-releaseStart
		return openPTY()
	}

	connectionCtx, cancelConnection := context.WithCancel(context.Background())
	ownerResult := make(chan error, 1)
	go func() {
		_, _, _, err := hub.attachRPC(
			connectionCtx,
			"connection-canceled-session",
			"owner",
			80,
			24,
			"sleep 30",
			"",
			false,
			false,
		)
		ownerResult <- err
	}()
	select {
	case <-startEntered:
	case <-time.After(5 * time.Second):
		t.Fatal("start owner never attempted PTY allocation")
	}

	waiterDoneObserved := make(chan struct{}, 1)
	releaseWaiterDone := make(chan struct{})
	waiterReleased := false
	defer func() {
		if !waiterReleased {
			close(releaseWaiterDone)
		}
	}()
	waiterResult := make(chan error, 1)
	go func() {
		_, _, _, err := hub.attachRPC(
			gatedDoneContext{
				Context:  connectionCtx,
				observed: waiterDoneObserved,
				release:  releaseWaiterDone,
			},
			"connection-canceled-session",
			"waiter",
			80,
			24,
			"sleep 30",
			"",
			false,
			false,
		)
		waiterResult <- err
	}()
	select {
	case <-waiterDoneObserved:
	case <-time.After(time.Second):
		close(releaseStart)
		t.Fatal("same-connection waiter did not join the in-flight start")
	}

	cancelConnection()
	close(releaseStart)
	if err := <-ownerResult; !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled start owner error = %v, want context canceled", err)
	}

	hub.mu.Lock()
	_, published := hub.sessions[persistentPTYSessionKey("connection-canceled-session")]
	hub.mu.Unlock()
	if published {
		t.Fatal("start published a session for waiters canceled before publication")
	}

	close(releaseWaiterDone)
	waiterReleased = true
	if err := <-waiterResult; !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled start waiter error = %v, want context canceled", err)
	}
}

func TestAttachRPCFastExitCoalescedWaitersShareGeneration(t *testing.T) {
	hub := newWebSocketPTYHub(wsPTYServerConfig{Shell: "/bin/sh"}, io.Discard)
	t.Cleanup(hub.closeAll)

	openPTY := hub.openPTY
	startEntered := make(chan struct{})
	releaseStart := make(chan struct{})
	var startCount atomic.Int32
	hub.openPTY = func() (*os.File, *os.File, error) {
		startCount.Add(1)
		close(startEntered)
		<-releaseStart
		return openPTY()
	}

	type attachResult struct {
		attachment  *wsPTYAttachment
		sessionDone <-chan struct{}
		err         error
	}
	attach := func(ctx context.Context, attachmentID string) <-chan attachResult {
		result := make(chan attachResult, 1)
		go func() {
			attachment, _, sessionDone, err := hub.attachRPC(
				ctx,
				"coalesced-fast-exit",
				attachmentID,
				80,
				24,
				"exit 0",
				"",
				false,
				false,
			)
			result <- attachResult{attachment: attachment, sessionDone: sessionDone, err: err}
		}()
		return result
	}

	firstResult := attach(context.Background(), "first")
	select {
	case <-startEntered:
	case <-time.After(5 * time.Second):
		t.Fatal("first fast-exit attach never attempted PTY allocation")
	}
	waiterJoined := make(chan struct{}, 1)
	releaseWaiter := make(chan struct{})
	secondResult := attach(
		gatedDoneContext{
			Context:  context.Background(),
			observed: waiterJoined,
			release:  releaseWaiter,
		},
		"second",
	)
	select {
	case <-waiterJoined:
	case <-time.After(time.Second):
		close(releaseStart)
		close(releaseWaiter)
		t.Fatal("second fast-exit attach did not join the in-flight generation")
	}
	close(releaseStart)

	first := <-firstResult
	if first.err != nil {
		close(releaseWaiter)
		t.Fatalf("first coalesced fast-exit attach: %v", first.err)
	}
	if first.attachment == nil || first.sessionDone == nil {
		close(releaseWaiter)
		t.Fatal("first coalesced fast-exit attach returned incomplete attachment")
	}
	select {
	case <-first.sessionDone:
	case <-time.After(5 * time.Second):
		close(releaseWaiter)
		t.Fatal("fast-exit process did not finish while its final claimant was pending")
	}

	hub.mu.Lock()
	session := hub.sessions[persistentPTYSessionKey("coalesced-fast-exit")]
	remainingClaims := 0
	initialPhase := wsPTYSessionInitialActive
	if session != nil {
		remainingClaims = session.initialClaims
		initialPhase = session.initialPhase
	}
	hub.mu.Unlock()
	if session == nil {
		close(releaseWaiter)
		t.Fatal("fast-exit generation was removed before its final claimant consumed it")
	}
	if remainingClaims != 1 {
		close(releaseWaiter)
		t.Fatalf("fast-exit generation claims = %d, want final pending claimant", remainingClaims)
	}
	if initialPhase != wsPTYSessionFinishedBeforeInitialAttachment {
		close(releaseWaiter)
		t.Fatalf("fast-exit generation phase = %d, want finished-before-initial-attachment", initialPhase)
	}
	if snapshots := hub.sessionSnapshots(); len(snapshots) != 0 {
		close(releaseWaiter)
		t.Fatalf("fast-exit generation remained visible as running: %+v", snapshots)
	}
	if status := hub.writeInputByID("coalesced-fast-exit", "first", "", nil); status != wsPTYInputWriteNotFound {
		close(releaseWaiter)
		t.Fatalf("fast-exit generation input status = %v, want not found", status)
	}
	if hub.resizeByID("coalesced-fast-exit", "first", "", 100, 30) {
		close(releaseWaiter)
		t.Fatal("fast-exit generation remained resizable")
	}

	close(releaseWaiter)
	second := <-secondResult
	results := []attachResult{first, second}
	for index, result := range results {
		if result.err != nil {
			t.Fatalf("coalesced fast-exit attach %d: %v", index+1, result.err)
		}
		if result.attachment == nil || result.sessionDone == nil {
			t.Fatalf("coalesced fast-exit attach %d returned incomplete attachment", index+1)
		}
		if result.sessionDone != first.sessionDone {
			t.Fatalf("coalesced fast-exit attach %d received a different generation", index+1)
		}
	}
	if got := startCount.Load(); got != 1 {
		t.Fatalf("coalesced fast-exit PTY start count = %d, want exactly 1", got)
	}
	hub.mu.Lock()
	_, retained := hub.sessions[persistentPTYSessionKey("coalesced-fast-exit")]
	hub.mu.Unlock()
	if retained {
		t.Fatal("fast-exit generation remained after its final initial claim")
	}
}

func TestAttachRPCLateCancellationSchedulesPublishedSessionReap(t *testing.T) {
	hub := newWebSocketPTYHub(wsPTYServerConfig{
		Shell:          "/bin/sh",
		SessionIdleTTL: time.Hour,
	}, io.Discard)
	t.Cleanup(hub.closeAll)

	baseCtx, cancel := context.WithCancel(context.Background())
	ctx := &cancelAfterFirstErrContext{Context: baseCtx, cancel: cancel}
	_, _, _, err := hub.attachRPC(
		ctx,
		"late-canceled-session",
		"late-canceled-attachment",
		80,
		24,
		"sleep 30",
		"",
		false,
		false,
	)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("late-canceled attach error = %v, want context canceled", err)
	}

	hub.mu.Lock()
	session := hub.sessions[persistentPTYSessionKey("late-canceled-session")]
	attachmentCount := 0
	hasIdleTimer := false
	if session != nil {
		attachmentCount = len(session.attachments)
		hasIdleTimer = session.idleTimer != nil
	}
	hub.mu.Unlock()
	if session == nil {
		t.Fatal("late-canceled published session was not retained for idle reaping")
	}
	if attachmentCount != 0 {
		t.Fatalf("late-canceled session attachments = %d, want 0", attachmentCount)
	}
	if !hasIdleTimer {
		t.Fatal("late-canceled published session has no idle reap timer")
	}

	reattached, _, _, err := hub.attachRPC(
		context.Background(),
		"late-canceled-session",
		"replacement-attachment",
		80,
		24,
		"",
		"",
		true,
		false,
	)
	if err != nil {
		t.Fatalf("reattach retained late-canceled session: %v", err)
	}
	hub.mu.Lock()
	session = hub.sessions[persistentPTYSessionKey("late-canceled-session")]
	attachmentCount = 0
	hasIdleTimer = false
	initialPhase := wsPTYSessionAwaitingInitialAttachment
	if session != nil {
		attachmentCount = len(session.attachments)
		hasIdleTimer = session.idleTimer != nil
		initialPhase = session.initialPhase
	}
	hub.mu.Unlock()
	if session == nil {
		t.Fatal("late-canceled session disappeared before replacement attach")
	}
	if attachmentCount != 1 {
		t.Fatalf("reattached late-canceled session attachments = %d, want 1", attachmentCount)
	}
	if hasIdleTimer {
		t.Fatal("reattached late-canceled session retained its idle reap timer")
	}
	if initialPhase != wsPTYSessionInitialActive {
		t.Fatalf("reattached late-canceled session phase = %d, want active", initialPhase)
	}

	hub.dropAttachment(reattached)
	session.terminateProcesses()
	session.closePTYFiles()
	waitForHubSessionCount(t, hub, 0, 5*time.Second)
}

func TestAnonymousAttachLateCancellationDropsPublishedSession(t *testing.T) {
	hub := newWebSocketPTYHub(wsPTYServerConfig{
		Shell:          "/bin/sh",
		SessionIdleTTL: time.Hour,
	}, io.Discard)
	t.Cleanup(hub.closeAll)

	baseCtx, cancel := context.WithCancel(context.Background())
	ctx := &cancelAfterFirstErrContext{Context: baseCtx, cancel: cancel}
	_, _, _, err := hub.prepareAttachment(
		ctx,
		"late-canceled-anonymous",
		"",
		80,
		24,
		false,
		"sleep 30",
		"",
		false,
		false,
	)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("late-canceled anonymous attach error = %v, want context canceled", err)
	}

	hub.mu.Lock()
	sessionCount := len(hub.sessions)
	hub.mu.Unlock()
	if sessionCount != 0 {
		t.Fatalf("anonymous sessions after late cancellation = %d, want 0", sessionCount)
	}
}

func TestAttachRPCBoundsStalledSessionStartOwners(t *testing.T) {
	hub := newWebSocketPTYHub(wsPTYServerConfig{Shell: "/bin/sh"}, io.Discard)
	t.Cleanup(hub.closeAll)

	startEntered := make(chan struct{}, maxConcurrentPTYSessionStartOwnersPerHub)
	releaseStarts := make(chan struct{})
	released := false
	t.Cleanup(func() {
		if !released {
			close(releaseStarts)
		}
	})
	hub.openPTY = func() (*os.File, *os.File, error) {
		startEntered <- struct{}{}
		<-releaseStarts
		return nil, nil, errors.New("test PTY start released")
	}

	results := make(chan error, maxConcurrentPTYSessionStartOwnersPerHub)
	for i := 0; i < maxConcurrentPTYSessionStartOwnersPerHub; i++ {
		go func(index int) {
			_, _, _, err := hub.attachRPC(
				context.Background(),
				"bounded-start-"+strconv.Itoa(index),
				"attachment",
				80,
				24,
				"sleep 30",
				"",
				false,
				false,
			)
			results <- err
		}(i)
	}
	for i := 0; i < maxConcurrentPTYSessionStartOwnersPerHub; i++ {
		select {
		case <-startEntered:
		case <-time.After(5 * time.Second):
			t.Fatalf("PTY start %d did not enter allocation", i+1)
		}
	}

	excessResult := make(chan rpcResponse, 1)
	server := &rpcServer{ptyHub: hub}
	go func() {
		excessResult <- server.handleRequest(rpcRequest{
			ID:     1,
			Method: "pty.attach",
			Params: map[string]any{
				"session_id":              "bounded-start-excess",
				"attachment_id":           "attachment",
				"client_attachment_token": "token",
				"cols":                    80,
				"rows":                    24,
				"command":                 "sleep 30",
			},
		})
	}()
	select {
	case response := <-excessResult:
		if response.Error == nil || response.Error.Code != "unavailable" {
			t.Fatalf("excess PTY start response = %+v, want unavailable error", response)
		}
		const wantMessage = "too many PTY sessions are already starting"
		if response.Error.Message != wantMessage {
			t.Fatalf("excess PTY start message = %q, want %q", response.Error.Message, wantMessage)
		}
	case <-time.After(time.Second):
		t.Fatal("excess PTY start blocked instead of failing immediately")
	}

	released = true
	close(releaseStarts)
	for i := 0; i < maxConcurrentPTYSessionStartOwnersPerHub; i++ {
		<-results
	}
}

func TestAttachRPCBoundsStalledSessionStartWaitersPerHub(t *testing.T) {
	hub := newWebSocketPTYHub(wsPTYServerConfig{Shell: "/bin/sh"}, io.Discard)
	t.Cleanup(hub.closeAll)

	const waiterLimit = 64
	startEntered := make(chan struct{})
	releaseStart := make(chan struct{})
	released := false
	t.Cleanup(func() {
		if !released {
			close(releaseStart)
		}
	})
	hub.openPTY = func() (*os.File, *os.File, error) {
		close(startEntered)
		<-releaseStart
		return nil, nil, errors.New("test PTY start released")
	}

	results := make(chan error, waiterLimit+1)
	attach := func(ctx context.Context, attachmentID string) {
		go func() {
			_, _, _, err := hub.attachRPC(
				ctx,
				"bounded-waiters",
				attachmentID,
				80,
				24,
				"sleep 30",
				"",
				false,
				false,
			)
			results <- err
		}()
	}
	attach(context.Background(), "owner")
	select {
	case <-startEntered:
	case <-time.After(5 * time.Second):
		t.Fatal("PTY start owner did not enter allocation")
	}

	for i := 0; i < waiterLimit; i++ {
		waiterJoined := make(chan struct{}, 1)
		attach(
			doneObservedContext{Context: context.Background(), observed: waiterJoined},
			"waiter-"+strconv.Itoa(i),
		)
		select {
		case <-waiterJoined:
		case <-time.After(time.Second):
			t.Fatalf("PTY start waiter %d did not join", i+1)
		}
	}

	excessResult := make(chan rpcResponse, 1)
	server := &rpcServer{ptyHub: hub}
	go func() {
		excessResult <- server.handleRequest(rpcRequest{
			ID:     1,
			Method: "pty.attach",
			Params: map[string]any{
				"session_id":              "bounded-waiters",
				"attachment_id":           "excess",
				"client_attachment_token": "token",
				"cols":                    80,
				"rows":                    24,
				"command":                 "sleep 30",
			},
		})
	}()
	select {
	case response := <-excessResult:
		if response.Error == nil || response.Error.Code != "unavailable" {
			t.Fatalf("excess PTY start waiter response = %+v, want unavailable error", response)
		}
		const wantMessage = "too many PTY session starts are already being awaited"
		if response.Error.Message != wantMessage {
			t.Fatalf("excess PTY start waiter message = %q, want %q", response.Error.Message, wantMessage)
		}
	case <-time.After(time.Second):
		t.Fatal("excess PTY start waiter blocked instead of failing immediately")
	}

	released = true
	close(releaseStart)
	for i := 0; i < waiterLimit+1; i++ {
		<-results
	}
}

func TestCloseAllDoesNotWaitForStalledSessionStart(t *testing.T) {
	hub := newWebSocketPTYHub(wsPTYServerConfig{Shell: "/bin/sh"}, io.Discard)
	t.Cleanup(hub.closeAll)

	openPTY := hub.openPTY
	startEntered := make(chan struct{})
	releaseStart := make(chan struct{})
	hub.openPTY = func() (*os.File, *os.File, error) {
		close(startEntered)
		<-releaseStart
		return openPTY()
	}

	attachResult := make(chan error, 1)
	go func() {
		_, _, _, err := hub.attachRPC(
			context.Background(),
			"closing-session",
			"closing-attachment",
			80,
			24,
			"sleep 30",
			"",
			false,
			false,
		)
		attachResult <- err
	}()
	select {
	case <-startEntered:
	case <-time.After(5 * time.Second):
		t.Fatal("session start never attempted PTY allocation")
	}

	closeDone := make(chan struct{})
	go func() {
		hub.closeAll()
		close(closeDone)
	}()
	select {
	case <-closeDone:
	case <-time.After(time.Second):
		close(releaseStart)
		<-attachResult
		t.Fatal("closeAll blocked behind a stalled session start")
	}

	close(releaseStart)
	err := <-attachResult
	if !errors.Is(err, errWSPTYHubClosed) {
		t.Fatalf("attach after closeAll error = %v, want PTY hub closed", err)
	}

	hub.mu.Lock()
	sessionCount := len(hub.sessions)
	pendingStarts := len(hub.startingSessions)
	hub.mu.Unlock()
	if sessionCount != 0 {
		t.Fatalf("published sessions after closeAll = %d, want 0", sessionCount)
	}
	if pendingStarts != 0 {
		t.Fatalf("pending session starts after completion = %d, want 0", pendingStarts)
	}
}

func TestPersistentPTYExecHelperKeepsHangupBlockedAcrossExec(t *testing.T) {
	if runtime.GOOS != "darwin" && runtime.GOOS != "linux" {
		t.Skip("persistent PTY exec helper is supported on Darwin and Linux")
	}
	if os.Getenv("BREE_PERSISTENT_PTY_EXEC_TEST_CHILD") == "1" {
		signal.Reset(syscall.SIGHUP)
		if err := syscall.Kill(os.Getpid(), syscall.SIGHUP); err != nil {
			t.Fatalf("send SIGHUP to helper child: %v", err)
		}
		_, _ = os.Stdout.WriteString("BREE_PERSISTENT_PTY_EXEC_SURVIVED\n")
		return
	}

	executable, err := os.Executable()
	if err != nil {
		t.Fatalf("resolve test executable: %v", err)
	}
	cmd := exec.Command(
		executable,
		persistentPTYExecHelperArgument,
		executable,
		executable,
		"-test.run",
		"^TestPersistentPTYExecHelperKeepsHangupBlockedAcrossExec$",
	)
	cmd.Env = append(os.Environ(), "BREE_PERSISTENT_PTY_EXEC_TEST_CHILD=1")
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("persistent PTY exec helper child failed: %v output=%q", err, output)
	}
	if !bytes.Contains(output, []byte("BREE_PERSISTENT_PTY_EXEC_SURVIVED")) {
		t.Fatalf("persistent PTY exec helper child did not survive SIGHUP: %q", output)
	}
}

func TestPersistentPTYExecHelperResolvesBareExecutableFromPATH(t *testing.T) {
	if runtime.GOOS != "darwin" && runtime.GOOS != "linux" {
		t.Skip("persistent PTY exec helper is supported on Darwin and Linux")
	}
	if os.Getenv("BREE_PERSISTENT_PTY_PATH_LOOKUP_TEST_CHILD") == "1" {
		_, _ = os.Stdout.WriteString("BREE_PERSISTENT_PTY_PATH_LOOKUP_OK\n")
		return
	}

	executable, err := os.Executable()
	if err != nil {
		t.Fatalf("resolve test executable: %v", err)
	}
	bin := t.TempDir()
	for _, helperName := range []string{"bash", "bree-custom-shell"} {
		t.Run(helperName, func(t *testing.T) {
			if err := os.Symlink(executable, filepath.Join(bin, helperName)); err != nil {
				t.Fatalf("link helper test executable: %v", err)
			}
			cmd := exec.Command(
				executable,
				persistentPTYExecHelperArgument,
				helperName,
				helperName,
				"-test.run",
				"^TestPersistentPTYExecHelperResolvesBareExecutableFromPATH$",
			)
			cmd.Env = append(os.Environ(),
				"PATH="+bin,
				"BREE_PERSISTENT_PTY_PATH_LOOKUP_TEST_CHILD=1",
			)
			output, err := cmd.CombinedOutput()
			if err != nil {
				t.Fatalf("persistent PTY exec helper did not resolve bare executable %q through PATH: %v output=%q", helperName, err, output)
			}
			if !bytes.Contains(output, []byte("BREE_PERSISTENT_PTY_PATH_LOOKUP_OK")) {
				t.Fatalf("persistent PTY exec helper child did not run through PATH: %q", output)
			}
		})
	}
}

func TestPersistentPTYCommandOverridesStaleExecHelperEnvironment(t *testing.T) {
	executable, err := os.Executable()
	if err != nil {
		t.Fatalf("resolve test executable: %v", err)
	}
	cmd := exec.Command("/bin/sh", "-c", `test "$BREE_PERSISTENT_PTY_EXEC_HELPER" = "$BREE_EXPECTED_PTY_EXEC_HELPER"`)
	cmd.Env = append(os.Environ(),
		persistentPTYExecHelperEnvironment+"=/missing/breed-remote",
		"BREE_EXPECTED_PTY_EXEC_HELPER="+executable,
	)
	wrapped, err := persistentPTYCommand(cmd)
	if err != nil {
		t.Fatalf("wrap persistent PTY command: %v", err)
	}
	if output, err := wrapped.CombinedOutput(); err != nil {
		t.Fatalf("wrapped command did not receive authoritative helper path: %v output=%q", err, output)
	}
}

func TestWebSocketPTYAnonymousHangupHelper(t *testing.T) {
	if os.Getenv("BREE_ANON_HUP_HELPER") != "1" {
		return
	}
	_, _ = os.Stdout.WriteString(
		"BREE_ANON_HUP_HELPER pid=" + strconv.Itoa(os.Getpid()) +
			" ignored=" + strconv.FormatBool(signal.Ignored(syscall.SIGHUP)) + "\n",
	)
	select {}
}

func TestTerminateProcessesSerializesPTYClose(t *testing.T) {
	ptyFile, err := os.Open(os.DevNull)
	if err != nil {
		t.Fatalf("open PTY stand-in: %v", err)
	}
	session := &wsPTYSession{ptyFile: ptyFile}
	lookupStarted := make(chan struct{})
	releaseLookup := make(chan struct{})
	terminated := make(chan struct{})
	go func() {
		session.terminateProcessesWithForegroundGroupLookup(func(*os.File) int {
			close(lookupStarted)
			<-releaseLookup
			return 0
		})
		close(terminated)
	}()
	<-lookupStarted

	closed := make(chan struct{})
	go func() {
		session.closePTYFile()
		close(closed)
	}()
	select {
	case <-closed:
		t.Fatal("PTY closed while foreground process-group lookup held its descriptor")
	case <-time.After(100 * time.Millisecond):
	}

	close(releaseLookup)
	select {
	case <-terminated:
	case <-time.After(5 * time.Second):
		t.Fatal("process termination did not finish after lookup was released")
	}
	select {
	case <-closed:
	case <-time.After(5 * time.Second):
		t.Fatal("PTY close did not finish after process termination released the descriptor")
	}
	if session.ptyFileSnapshot() != nil {
		t.Fatal("closed PTY descriptor remained available to later operations")
	}
}

func TestTerminateProcessesRunsOnlyOnce(t *testing.T) {
	ptyFile, err := os.Open(os.DevNull)
	if err != nil {
		t.Fatalf("open PTY stand-in: %v", err)
	}
	t.Cleanup(func() { _ = ptyFile.Close() })

	session := &wsPTYSession{ptyFile: ptyFile}
	lookupCount := 0
	lookup := func(*os.File) int {
		lookupCount++
		return 0
	}
	session.terminateProcessesWithForegroundGroupLookup(lookup)
	session.terminateProcessesWithForegroundGroupLookup(lookup)

	if lookupCount != 1 {
		t.Fatalf("process teardown ran %d times, want exactly once", lookupCount)
	}
}

func TestWaitSessionProcessDrainsBufferedOutputBeforeForcedMasterClose(t *testing.T) {
	master, slave, err := os.Pipe()
	if err != nil {
		t.Fatalf("open buffered output pipe: %v", err)
	}
	heldSlaveFD, err := syscall.Dup(int(slave.Fd()))
	if err != nil {
		_ = master.Close()
		_ = slave.Close()
		t.Fatalf("duplicate escaped slave holder: %v", err)
	}
	heldSlave := os.NewFile(uintptr(heldSlaveFD), "escaped-slave-holder")
	t.Cleanup(func() {
		_ = master.Close()
		_ = slave.Close()
		_ = heldSlave.Close()
	})

	const marker = "BREE_BUFFERED_FAST_EXIT_OUTPUT\n"
	if _, err := slave.Write([]byte(marker)); err != nil {
		t.Fatalf("buffer fast-exit output: %v", err)
	}
	command := exec.Command("/bin/sh", "-c", "exit 0")
	if err := command.Start(); err != nil {
		t.Fatalf("start fast-exit command: %v", err)
	}

	hub := newWebSocketPTYHub(wsPTYServerConfig{}, io.Discard)
	t.Cleanup(hub.closeAll)
	session := &wsPTYSession{
		id:           "buffered-fast-exit",
		key:          persistentPTYSessionKey("buffered-fast-exit"),
		cmd:          command,
		ptyFile:      master,
		ttyFile:      slave,
		attachments:  map[string]*wsPTYAttachment{},
		done:         make(chan struct{}),
		initialPhase: wsPTYSessionInitialActive,
	}
	hub.sessions[session.key] = session

	go hub.pumpSession(session)
	waiterDone := make(chan struct{})
	go func() {
		hub.waitSessionProcess(session)
		close(waiterDone)
	}()

	select {
	case <-waiterDone:
	case <-time.After(defaultPTYExitDrainTimeout + 2*time.Second):
		t.Fatal("process waiter did not force-close the master after its drain deadline")
	}
	select {
	case <-session.done:
	case <-time.After(time.Second):
		t.Fatal("forced master close did not finish the escaped-holder session")
	}

	if got := string(session.scrollback); got != marker {
		t.Fatalf("drained buffered output = %q, want %q", got, marker)
	}
	if _, err := heldSlave.Stat(); err != nil {
		t.Fatalf("escaped slave holder closed before the master drain deadline: %v", err)
	}
}

func TestWebSocketPTYReattachWritesAcceptedOldInputBeforeNew(t *testing.T) {
	hub, session, attachment, readFile, writeFile, done := newTestPTYInputSession(t, "sess-reattach-seam", "same", false)
	defer close(done)
	defer readFile.Close()
	defer writeFile.Close()

	go hub.writeInputLoop(session)
	session.ptyWriteMu.Lock()
	if status := hub.writeInputByID(session.id, attachment.id, attachment.clientToken, []byte("OLD")); status != wsPTYInputWriteOK {
		session.ptyWriteMu.Unlock()
		t.Fatalf("old write status = %v, want ok", status)
	}

	attachDone := make(chan *wsPTYAttachment, 1)
	go func() {
		newAttachment, _, _, err := hub.prepareAttachment(
			context.Background(),
			session.id,
			attachment.id,
			80,
			24,
			true,
			"",
			"new-token",
			true,
			false,
		)
		if err != nil {
			t.Errorf("prepare replacement attachment: %v", err)
			attachDone <- nil
			return
		}
		attachDone <- newAttachment
	}()

	// Reattach must complete while the PTY writer is still stalled — a
	// wedged reader must never turn reattach into an indefinite hang.
	var newAttachment *wsPTYAttachment
	select {
	case newAttachment = <-attachDone:
	case <-time.After(5 * time.Second):
		session.ptyWriteMu.Unlock()
		t.Fatal("reattach blocked behind a stalled PTY writer")
	}
	if newAttachment == nil {
		session.ptyWriteMu.Unlock()
		t.Fatal("replacement attachment was not created")
	}
	if status := hub.writeInputByID(session.id, newAttachment.id, newAttachment.clientToken, []byte("NEW")); status != wsPTYInputWriteOK {
		session.ptyWriteMu.Unlock()
		t.Fatalf("new write status = %v, want ok", status)
	}
	session.ptyWriteMu.Unlock()
	if got := readExactlyFromFile(t, readFile, 6, 5*time.Second); string(got) != "OLDNEW" {
		t.Fatalf("PTY input = %q, want OLDNEW", string(got))
	}
}

func TestWebSocketPTYResizeDoesNotWaitForPTYWriter(t *testing.T) {
	for _, action := range []string{"resize", "reattach"} {
		t.Run(action, func(t *testing.T) {
			hub, session, attachment, readFile, writeFile, done := newTestPTYInputSession(t, "sess-resize-writer", "attachment", false)
			defer close(done)
			defer readFile.Close()
			defer writeFile.Close()
			master, slave, err := pty.Open()
			if err != nil {
				t.Fatal(err)
			}
			defer master.Close()
			defer slave.Close()
			session.ptyFile = master

			// Hold the input writer at the point where a full PTY buffer stalls
			// it, then verify both public operations still resize the real PTY.
			session.ptyWriteMu.Lock()
			resizeDone := make(chan error, 1)
			go func() {
				if action == "resize" {
					hub.resize(attachment, 100, 35)
					resizeDone <- nil
				} else {
					_, _, _, err := hub.prepareAttachment(context.Background(),
						session.id, attachment.id, 100, 35, true, "", "new-token", true, false)
					resizeDone <- err
				}
			}()
			select {
			case err := <-resizeDone:
				session.ptyWriteMu.Unlock()
				if err != nil {
					t.Fatal(err)
				}
			case <-time.After(5 * time.Second):
				session.ptyWriteMu.Unlock()
				<-resizeDone
				t.Fatal("resize blocked behind a stalled PTY writer")
			}
			size, err := pty.GetsizeFull(master)
			if err != nil {
				t.Fatal(err)
			}
			if size.Cols != 100 || size.Rows != 35 {
				t.Fatalf("terminal size = %dx%d, want 100x35", size.Cols, size.Rows)
			}
		})
	}
}

func TestWebSocketPTYInputSeqEnforcement(t *testing.T) {
	hub, session, attachment, readFile, writeFile, done := newTestPTYInputSession(t, "sess-seq", "seq-att", true)
	defer close(done)
	defer readFile.Close()
	defer writeFile.Close()
	attachment.inputSeqAck = true

	go hub.writeInputLoop(session)
	if result := hub.writeInputByIDWithSeq(session.id, attachment.id, attachment.clientToken, []byte("A"), 1, true); result.status != wsPTYInputWriteOK {
		t.Fatalf("seq 1 status = %v, want ok", result.status)
	}
	if result := hub.writeInputByIDWithSeq(session.id, attachment.id, attachment.clientToken, []byte("B"), 2, true); result.status != wsPTYInputWriteOK {
		t.Fatalf("seq 2 status = %v, want ok", result.status)
	}
	if result := hub.writeInputByIDWithSeq(session.id, attachment.id, attachment.clientToken, []byte("D"), 4, true); result.status != wsPTYInputWriteSeqGap || result.got != 4 || result.want != 3 {
		t.Fatalf("seq 4 result = %+v, want gap got=4 want=3", result)
	}
	if got := readExactlyFromFile(t, readFile, 2, 5*time.Second); string(got) != "AB" {
		t.Fatalf("PTY input = %q, want AB", string(got))
	}

	replacement, _, _, err := hub.prepareAttachment(context.Background(), session.id, attachment.id, 80, 24, true, "", "seq-token-2", true, true)
	if err != nil {
		t.Fatalf("prepare replacement attachment: %v", err)
	}
	if result := hub.writeInputByIDWithSeq(session.id, replacement.id, replacement.clientToken, []byte("C"), 1, true); result.status != wsPTYInputWriteOK {
		t.Fatalf("fresh attachment seq 1 status = %v, want ok", result.status)
	}
	if got := readExactlyFromFile(t, readFile, 1, 5*time.Second); string(got) != "C" {
		t.Fatalf("fresh PTY input = %q, want C", string(got))
	}
}

func TestWebSocketPTYSaturatedAckQueueDropsAttachment(t *testing.T) {
	hub, session, attachment, readFile, writeFile, done := newTestPTYInputSession(t, "sess-ack-full", "ack-att", true)
	defer close(done)
	defer readFile.Close()
	defer writeFile.Close()
	attachment.inputSeqAck = true

	// Saturate the send queue so the coalesced ack frame cannot be queued.
	for i := 0; i < cap(attachment.send); i++ {
		attachment.send <- wsPTYOutgoingFrame{}
	}
	chunk := wsPTYInputChunk{
		attachmentID:  attachment.id,
		attachment:    attachment,
		payload:       []byte("x"),
		seq:           1,
		finalSeqChunk: true,
	}
	if !hub.writeInputChunk(session, chunk) {
		t.Fatal("payload write should still succeed")
	}
	if got := readExactlyFromFile(t, readFile, 1, 5*time.Second); string(got) != "x" {
		t.Fatalf("PTY input = %q, want x", string(got))
	}
	hub.mu.Lock()
	_, stillAttached := session.attachments[attachment.id]
	hub.mu.Unlock()
	if stillAttached {
		t.Fatal("attachment with a saturated ack queue should be dropped, not leaked")
	}
}

func TestWebSocketPTYWriteRejectsMalformedSeq(t *testing.T) {
	hub, _, attachment, readFile, writeFile, done := newTestPTYInputSession(t, "sess-seq-invalid", "seq-att", true)
	defer close(done)
	defer readFile.Close()
	defer writeFile.Close()
	attachment.inputSeqAck = true

	server := &rpcServer{ptyHub: hub, frameWriter: &captureRPCFrameWriter{}}
	for _, badSeq := range []any{"not-a-number", -1, 1.5} {
		req := rpcRequest{
			Method: "pty.write",
			Params: map[string]any{
				"session_id":              "sess-seq-invalid",
				"attachment_id":           "seq-att",
				"client_attachment_token": "token-1",
				"data_base64":             base64.StdEncoding.EncodeToString([]byte("x")),
				"seq":                     badSeq,
			},
		}
		resp := server.handlePTYWrite(req)
		if resp.OK || resp.Error == nil || resp.Error.Code != "invalid_params" {
			t.Fatalf("seq=%v response = %+v, want invalid_params", badSeq, resp)
		}
	}
}

func TestWebSocketPTYInputSeqGapNotificationEmitsPTYError(t *testing.T) {
	hub, _, attachment, readFile, writeFile, done := newTestPTYInputSession(t, "sess-seq-event", "seq-att", true)
	defer close(done)
	defer readFile.Close()
	defer writeFile.Close()
	attachment.inputSeqAck = true

	writer := &captureRPCFrameWriter{}
	server := &rpcServer{ptyHub: hub, frameWriter: writer}
	req := rpcRequest{
		Method: "pty.write",
		Params: map[string]any{
			"session_id":              "sess-seq-event",
			"attachment_id":           "seq-att",
			"client_attachment_token": "token-1",
			"data_base64":             base64.StdEncoding.EncodeToString([]byte("gap")),
			"seq":                     2,
		},
	}
	resp := server.handlePTYWrite(req)
	if resp.OK || resp.Error == nil || resp.Error.Code != "pty_input_seq_gap" {
		t.Fatalf("gapped write response = %+v, want pty_input_seq_gap", resp)
	}
	if err := server.handleNotificationResponse(req, resp); err != nil {
		t.Fatalf("handle notification response: %v", err)
	}
	if len(writer.events) != 1 {
		t.Fatalf("events = %d, want 1", len(writer.events))
	}
	event := writer.events[0]
	if event.Event != "pty.error" || !strings.Contains(event.Message, "got 2, want 1") {
		t.Fatalf("event = %+v, want visible seq gap pty.error", event)
	}
	hub.mu.Lock()
	_, stillAttached := hub.sessions[persistentPTYSessionKey("sess-seq-event")].attachments["seq-att"]
	hub.mu.Unlock()
	if stillAttached {
		t.Fatal("seq-gap error should detach the attachment, not leave it registered")
	}
}

func TestWebSocketPTYInputAckEmission(t *testing.T) {
	hub, session, attachment, readFile, writeFile, done := newTestPTYInputSession(t, "sess-ack", "ack-att", true)
	defer close(done)
	defer readFile.Close()
	defer writeFile.Close()
	attachment.inputSeqAck = true

	for seq := uint64(1); seq <= 10; seq++ {
		chunk := wsPTYInputChunk{
			attachmentID:  attachment.id,
			attachment:    attachment,
			payload:       []byte("x"),
			seq:           seq,
			finalSeqChunk: true,
		}
		if !hub.writeInputChunk(session, chunk) {
			t.Fatalf("write seq %d failed", seq)
		}
	}
	frame := <-attachment.send
	event := rpcPTYEventForFrame(attachment, frame)
	if event.Event != "pty.input_ack" || event.Seq != 10 {
		t.Fatalf("ack event = %+v, want cumulative seq 10", event)
	}
	select {
	case extra := <-attachment.send:
		t.Fatalf("ack was not coalesced; extra frame=%+v", extra)
	default:
	}

	legacyAttachment := &wsPTYAttachment{
		sessionKey:  session.key,
		id:          "legacy-att",
		clientToken: "legacy-token",
		send:        make(chan wsPTYOutgoingFrame, defaultWebSocketWriteQueueCap),
		cancel:      func() {},
		persistent:  true,
		inputSeqAck: false,
	}
	hub.mu.Lock()
	session.attachments[legacyAttachment.id] = legacyAttachment
	hub.mu.Unlock()
	chunk := wsPTYInputChunk{
		attachmentID:  legacyAttachment.id,
		attachment:    legacyAttachment,
		payload:       []byte("y"),
		seq:           1,
		finalSeqChunk: true,
	}
	if !hub.writeInputChunk(session, chunk) {
		t.Fatal("legacy write failed")
	}
	select {
	case frame := <-legacyAttachment.send:
		t.Fatalf("legacy attachment received unexpected ack frame=%+v", frame)
	default:
	}
}

func TestWebSocketPTYInputBackpressureDoesNotBlockHub(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe: %v", err)
	}
	defer reader.Close()

	stderr := newNotifyingBuffer()
	hub := newWebSocketPTYHub(wsPTYServerConfig{
		Shell:           "/bin/sh",
		ScrollbackLimit: 4096,
	}, stderr)
	sessionKey := persistentPTYSessionKey("sess-input-backpressure")
	sessionDone := make(chan struct{})
	attachment := &wsPTYAttachment{
		sessionKey: sessionKey,
		id:         "att-input",
		cols:       80,
		rows:       24,
		send:       make(chan wsPTYOutgoingFrame, defaultWebSocketWriteQueueCap),
		cancel:     func() {},
		persistent: true,
	}
	session := &wsPTYSession{
		id:            "sess-input-backpressure",
		key:           sessionKey,
		ptyFile:       writer,
		attachments:   map[string]*wsPTYAttachment{attachment.id: attachment},
		effectiveCols: 80,
		effectiveRows: 24,
		lastKnownCols: 80,
		lastKnownRows: 24,
		input:         make(chan wsPTYInputChunk, defaultPTYInputQueueCap),
		done:          sessionDone,
	}
	defer func() {
		_ = writer.Close()
		close(sessionDone)
	}()

	hub.mu.Lock()
	hub.sessions[session.key] = session
	hub.mu.Unlock()
	go hub.writeInputLoop(session)

	payload := bytes.Repeat([]byte("x"), 64*1024)
	writesDone := make(chan struct{})
	go func() {
		defer close(writesDone)
		for i := 0; i < defaultPTYInputQueueCap*4; i++ {
			_ = hub.writeInputByID(session.id, attachment.id, "", payload)
		}
	}()

	select {
	case <-writesDone:
	case <-time.After(2 * time.Second):
		t.Fatal("writeInputByID blocked behind a full PTY writer")
	}

	closeDone := make(chan bool, 1)
	go func() {
		closeDone <- hub.closeSessionByID(session.id)
	}()
	select {
	case ok := <-closeDone:
		if !ok {
			t.Fatal("closeSessionByID returned false")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("closeSessionByID blocked behind a full PTY writer")
	}
}

func TestWebSocketPTYInputBackpressureRejectsWholePayload(t *testing.T) {
	stderr := newNotifyingBuffer()
	hub := newWebSocketPTYHub(wsPTYServerConfig{
		Shell:           "/bin/sh",
		ScrollbackLimit: 4096,
	}, stderr)
	sessionKey := persistentPTYSessionKey("sess-input-atomic")
	sessionDone := make(chan struct{})
	attachment := &wsPTYAttachment{
		sessionKey: sessionKey,
		id:         "att-input",
		cols:       80,
		rows:       24,
		send:       make(chan wsPTYOutgoingFrame, defaultWebSocketWriteQueueCap),
		cancel:     func() {},
		persistent: true,
	}
	session := &wsPTYSession{
		id:            "sess-input-atomic",
		key:           sessionKey,
		attachments:   map[string]*wsPTYAttachment{attachment.id: attachment},
		effectiveCols: 80,
		effectiveRows: 24,
		lastKnownCols: 80,
		lastKnownRows: 24,
		input:         make(chan wsPTYInputChunk, defaultPTYInputQueueCap),
		done:          sessionDone,
	}
	defer close(sessionDone)

	hub.mu.Lock()
	hub.sessions[session.key] = session
	hub.mu.Unlock()

	for i := 0; i < defaultPTYInputQueueCap-1; i++ {
		session.input <- wsPTYInputChunk{
			attachmentID: attachment.id,
			attachment:   attachment,
			payload:      []byte("queued"),
		}
	}

	payload := append(
		bytes.Repeat([]byte("x"), defaultPTYInputChunkBytes),
		'y',
	)
	if status := hub.writeInputByID(session.id, attachment.id, "", payload); status != wsPTYInputWriteQueueFull {
		t.Fatalf("writeInputByID status = %v, want queue full", status)
	}
	if len(session.input) == defaultPTYInputQueueCap {
		t.Fatal("writeInputByID unexpectedly accepted a two-chunk payload with one queue slot free")
	}
	if got := len(session.input); got != defaultPTYInputQueueCap-1 {
		t.Fatalf("input queue length = %d, want unchanged %d", got, defaultPTYInputQueueCap-1)
	}
	for len(session.input) > 0 {
		chunk := <-session.input
		if bytes.Contains(chunk.payload, []byte("x")) || bytes.Contains(chunk.payload, []byte("y")) {
			t.Fatalf("rejected payload chunk was partially enqueued: %q", string(chunk.payload))
		}
	}
	if !strings.Contains(stderr.String(), "ws pty input queue full") {
		t.Fatalf("stderr should report input queue backpressure, got %q", stderr.String())
	}
}

func newTestPTYInputSession(t *testing.T, sessionID string, attachmentID string, inputSeqAck bool) (*wsPTYHub, *wsPTYSession, *wsPTYAttachment, *os.File, *os.File, chan struct{}) {
	t.Helper()
	readFile, writeFile, err := os.Pipe()
	if err != nil {
		t.Fatalf("create pipe: %v", err)
	}
	hub := newWebSocketPTYHub(wsPTYServerConfig{
		Shell:           "/bin/sh",
		ScrollbackLimit: 4096,
	}, newNotifyingBuffer())
	sessionKey := persistentPTYSessionKey(sessionID)
	done := make(chan struct{})
	attachment := &wsPTYAttachment{
		sessionKey:  sessionKey,
		id:          attachmentID,
		clientToken: "token-1",
		cols:        80,
		rows:        24,
		send:        make(chan wsPTYOutgoingFrame, defaultWebSocketWriteQueueCap),
		cancel:      func() {},
		persistent:  true,
		inputSeqAck: inputSeqAck,
	}
	session := &wsPTYSession{
		id:            sessionID,
		key:           sessionKey,
		ptyFile:       writeFile,
		attachments:   map[string]*wsPTYAttachment{attachment.id: attachment},
		effectiveCols: 80,
		effectiveRows: 24,
		lastKnownCols: 80,
		lastKnownRows: 24,
		input:         make(chan wsPTYInputChunk, defaultPTYInputQueueCap),
		done:          done,
	}
	hub.mu.Lock()
	hub.sessions[session.key] = session
	hub.mu.Unlock()
	return hub, session, attachment, readFile, writeFile, done
}

func readExactlyFromFile(t *testing.T, file *os.File, count int, timeout time.Duration) []byte {
	t.Helper()
	type readResult struct {
		data []byte
		err  error
	}
	resultCh := make(chan readResult, 1)
	go func() {
		buf := make([]byte, count)
		_, err := io.ReadFull(file, buf)
		resultCh <- readResult{data: buf, err: err}
	}()
	select {
	case result := <-resultCh:
		if result.err != nil {
			t.Fatalf("read PTY input: %v", result.err)
		}
		return result.data
	case <-time.After(timeout):
		t.Fatalf("timed out reading %d PTY bytes", count)
		return nil
	}
}

type captureRPCFrameWriter struct {
	events []rpcEvent
}

func (w *captureRPCFrameWriter) writeResponse(rpcResponse) error {
	return nil
}

func (w *captureRPCFrameWriter) writeEvent(event rpcEvent) error {
	w.events = append(w.events, event)
	return nil
}

func TestWebSocketPTYCountsIdleSessionUntilTeardownCompletes(t *testing.T) {
	hub := newWebSocketPTYHub(wsPTYServerConfig{}, io.Discard)
	sessionKey := persistentPTYSessionKey("teardown-in-flight")
	session := &wsPTYSession{
		id:          "teardown-in-flight",
		key:         sessionKey,
		attachments: map[string]*wsPTYAttachment{},
		done:        make(chan struct{}),
	}
	hub.mu.Lock()
	hub.sessions[sessionKey] = session
	hub.mu.Unlock()

	// Hold the PTY-file mutex so the idle reaper can remove the session from
	// the map but cannot finish terminateProcesses or closePTYFiles.
	session.ptyFileMu.Lock()
	ptyFileLocked := true
	teardownDone := make(chan struct{})
	go func() {
		hub.reapIdleSession(session)
		close(teardownDone)
	}()
	defer func() {
		if ptyFileLocked {
			session.ptyFileMu.Unlock()
			<-teardownDone
		}
	}()

	deadline := time.Now().Add(2 * time.Second)
	for {
		hub.mu.Lock()
		_, retained := hub.sessions[sessionKey]
		hub.mu.Unlock()
		if !retained {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("idle reaper did not begin session teardown")
		}
		runtime.Gosched()
	}

	if got := hub.activeSessionCount(); got != 1 {
		t.Fatalf("hub activity during session teardown = %d, want 1", got)
	}
	session.ptyFileMu.Unlock()
	ptyFileLocked = false
	select {
	case <-teardownDone:
	case <-time.After(2 * time.Second):
		t.Fatalf("idle session teardown did not finish")
	}
	if got := hub.activeSessionCount(); got != 0 {
		t.Fatalf("hub activity after session teardown = %d, want 0", got)
	}
}

func TestWebSocketPTYScrollbackDoesNotRetainOversizedChunks(t *testing.T) {
	hub := newWebSocketPTYHub(wsPTYServerConfig{
		Shell:           "/bin/sh",
		ScrollbackLimit: 4096,
	}, newNotifyingBuffer())
	session := &wsPTYSession{id: "scrollback"}

	hub.mu.Lock()
	hub.appendScrollbackLocked(session, bytes.Repeat([]byte("x"), 1<<20))
	hub.mu.Unlock()
	if got := len(session.scrollback); got != 4096 {
		t.Fatalf("scrollback len = %d, want 4096", got)
	}
	if got := cap(session.scrollback); got > 4096 {
		t.Fatalf("scrollback cap = %d, want <= 4096", got)
	}

	hub.mu.Lock()
	hub.appendScrollbackLocked(session, []byte("tail"))
	hub.mu.Unlock()
	if got := len(session.scrollback); got != 4096 {
		t.Fatalf("scrollback len after append = %d, want 4096", got)
	}
	if got := cap(session.scrollback); got > 4096 {
		t.Fatalf("scrollback cap after append = %d, want <= 4096", got)
	}
	replay := session.scrollbackSnapshot()
	if !strings.HasSuffix(string(replay), "tail") {
		t.Fatalf("scrollback should retain newest output, got suffix %q", string(replay[len(replay)-16:]))
	}
}

func TestDefaultWebSocketPTYEnvAddsStandardExecutableDirectories(t *testing.T) {
	tests := []struct {
		name          string
		inheritedPath string
	}{
		{name: "restricted daemon PATH", inheritedPath: "/opt/bree/bin"},
		{name: "empty daemon PATH", inheritedPath: ""},
		{name: "partially complete daemon PATH", inheritedPath: "/opt/bree/bin:/usr/bin"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Setenv("PATH", test.inheritedPath)

			env, _ := envMapWithOrder(defaultWebSocketPTYEnv("/bin/sh"))
			pathEntries := strings.Split(env["PATH"], string(os.PathListSeparator))
			inheritedPrefix := test.inheritedPath + string(os.PathListSeparator)
			if test.inheritedPath != "" && env["PATH"] != test.inheritedPath && !strings.HasPrefix(env["PATH"], inheritedPrefix) {
				t.Fatalf("PATH should preserve inherited entries first, got %q", env["PATH"])
			}
			for _, standardDirectory := range []string{
				"/usr/local/bin",
				"/usr/bin",
				"/bin",
				"/usr/local/sbin",
				"/usr/sbin",
				"/sbin",
			} {
				if count := countStrings(pathEntries, standardDirectory); count != 1 {
					t.Errorf("PATH %q contains standard directory %q %d times, want once", env["PATH"], standardDirectory, count)
				}
			}
		})
	}
}

func countStrings(values []string, target string) int {
	count := 0
	for _, value := range values {
		if value == target {
			count++
		}
	}
	return count
}

func waitForHubSessionCount(t *testing.T, hub *wsPTYHub, want int, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if got := hub.activeSessionCount(); got == want {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("hub session count = %d, want %d", hub.activeSessionCount(), want)
}

func waitForHubSessionSize(t *testing.T, hub *wsPTYHub, sessionID string, wantAttachments int, wantCols int, wantRows int, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		attachments, cols, rows, ok := hub.sessionDebugSnapshot(sessionID)
		if ok && attachments == wantAttachments && cols == wantCols && rows == wantRows {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	attachments, cols, rows, ok := hub.sessionDebugSnapshot(sessionID)
	t.Fatalf(
		"hub session %s state = ok:%v attachments:%d size:%dx%d, want attachments:%d size:%dx%d",
		sessionID,
		ok,
		attachments,
		cols,
		rows,
		wantAttachments,
		wantCols,
		wantRows,
	)
}

func waitForHubPTYSize(t *testing.T, hub *wsPTYHub, sessionID string, wantCols int, wantRows int, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		cols, rows, ok, err := hub.sessionPTYSize(sessionID)
		if err != nil {
			t.Fatalf("read pty size for %s: %v", sessionID, err)
		}
		if ok && cols == wantCols && rows == wantRows {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	cols, rows, ok, err := hub.sessionPTYSize(sessionID)
	t.Fatalf("hub session %s pty size = ok:%v size:%dx%d err:%v, want %dx%d", sessionID, ok, cols, rows, err, wantCols, wantRows)
}

func waitForGoroutineCeiling(t *testing.T, ceiling int, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		runtime.GC()
		if got := runtime.NumGoroutine(); got <= ceiling {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("goroutine count = %d, want <= %d", runtime.NumGoroutine(), ceiling)
}

func (h *wsPTYHub) sessionDebugSnapshot(sessionID string) (attachments int, effectiveCols int, effectiveRows int, ok bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	session := h.sessions[persistentPTYSessionKey(sessionID)]
	if session == nil {
		return 0, 0, 0, false
	}
	return len(session.attachments), session.effectiveCols, session.effectiveRows, true
}

func (h *wsPTYHub) debugAttachment(sessionID string, attachmentID string) *wsPTYAttachment {
	h.mu.Lock()
	defer h.mu.Unlock()
	session := h.sessions[persistentPTYSessionKey(sessionID)]
	if session == nil {
		return nil
	}
	return session.attachments[attachmentID]
}

func (h *wsPTYHub) sessionPTYSize(sessionID string) (cols int, rows int, ok bool, err error) {
	h.mu.Lock()
	session := h.sessions[persistentPTYSessionKey(sessionID)]
	if session == nil {
		h.mu.Unlock()
		return 0, 0, false, nil
	}
	h.mu.Unlock()

	session.ptyResizeMu.Lock()
	defer session.ptyResizeMu.Unlock()
	var size *pty.Winsize
	available := session.withPTYFileLocked(func(sizeFile *os.File) {
		size, err = pty.GetsizeFull(sizeFile)
	})
	if !available {
		return 0, 0, true, os.ErrClosed
	}
	if err != nil {
		return 0, 0, true, err
	}
	return int(size.Cols), int(size.Rows), true, nil
}
