import Darwin
import Foundation
import Testing

@testable import BreeFoundation

@Suite(.serialized)
struct SSHForegroundAuthenticationRetryPolicyTests {
    @Test(arguments: [
        "user@example.test: Permission denied (publickey,password).",
        "Bad owner or permissions on /Users/test/.ssh/config",
    ])
    func preservesPermanentAuthenticationFailure(_ diagnostic: String) throws {
        let result = try run(
            "printf '%s\\n' '\(diagnostic)' >&2; exit 255"
        )

        #expect(result.status == 255)
        #expect(result.stderr.contains(diagnostic))
        #expect(result.temporaryFiles.isEmpty)
    }

    @Test func distinguishesUnclassifiedFailureFromPermanentFailure() throws {
        let result = try run("exit 255")

        #expect(result.status == 252)
        #expect(result.temporaryFiles.isEmpty)
    }

    @Test func preservesNonSSHFailureStatus() throws {
        let result = try run("exit 3")

        #expect(result.status == 3)
        #expect(result.temporaryFiles.isEmpty)
    }

    @Test func pinsDiagnosticLocaleForWrappedAuthenticationCommand() throws {
        let result = try run(
            """
            if [ "${LC_ALL:-}" != C ] || [ "${LANG:-}" != C ]; then exit 3; fi
            printf '%s\\n' 'ssh: connect to host example.test port 22: Network is unreachable' >&2
            exit 255
            """
        )

        #expect(result.status == 254)
        #expect(result.temporaryFiles.isEmpty)
    }

    @Test func permanentFailureTakesPrecedenceOverEarlierTransportDiagnostic() throws {
        let result = try run(
            """
            printf '%s\\n' 'debug1: connect to address 2001:db8::1 port 22: Network is unreachable' >&2
            printf '%s\\n' 'user@example.test: Permission denied (publickey,password).' >&2
            exit 255
            """
        )

        #expect(result.status == 255)
        #expect(result.stderr.contains("Network is unreachable"))
        #expect(result.stderr.contains("Permission denied"))
        #expect(result.temporaryFiles.isEmpty)
    }

    @Test func mapsTemporaryDNSResolutionFailureToRetryableStatus() throws {
        let result = try run(
            """
            printf '%s\\n' \
              'ssh: Could not resolve hostname example.test: Temporary failure in name resolution' >&2
            exit 255
            """
        )

        #expect(result.status == 254)
        #expect(result.stderr.contains("Temporary failure in name resolution"))
        #expect(result.temporaryFiles.isEmpty)
    }

    @Test func mapsServerAliveTimeoutToRetryableStatus() throws {
        let result = try run(
            "printf '%s\\n' 'Timeout, server example.test not responding.' >&2; exit 255"
        )

        #expect(result.status == 254)
        #expect(result.stderr.contains("Timeout, server example.test not responding."))
        #expect(result.temporaryFiles.isEmpty)
    }

    @Test(arguments: [
        "Connection to 192.0.2.1 port 22 timed out",
        "Connection to example.test closed by remote host.",
        "send disconnect: Connection to 192.0.2.1 port 22: Broken pipe",
        "ssh: connect to host example.test port 22: Network is down",
        "ssh: connect to host example.test port 22: Host is down",
    ])
    func mapsStandardOpenSSHTransportDiagnosticToRetryableStatus(_ diagnostic: String) throws {
        let result = try run("printf '%s\\n' '\(diagnostic)' >&2; exit 255")

        #expect(result.status == 254)
        #expect(result.stderr.contains(diagnostic))
        #expect(result.temporaryFiles.isEmpty)
    }

    @Test(arguments: ["Connection refused", "Connection reset by peer"])
    func mapsDirectConnectionStartupFailureToRetryableStatus(_ diagnostic: String) throws {
        let result = try run(
            "printf '%s\\n' 'ssh: connect to host example.test port 22: \(diagnostic)' >&2; exit 255"
        )

        #expect(result.status == 254)
        #expect(result.stderr.contains(diagnostic))
        #expect(result.temporaryFiles.isEmpty)
    }

    @Test func mapsAddressQualifiedConnectionResetToRetryableStatus() throws {
        let result = try run(
            "printf '%s\\n' 'Connection reset by 192.0.2.1 port 22' >&2; exit 255"
        )

        #expect(result.status == 254)
        #expect(result.stderr.contains("Connection reset by 192.0.2.1 port 22"))
        #expect(result.temporaryFiles.isEmpty)
    }

    @Test(arguments: [
        "Connection closed by UNKNOWN port 65535",
        "ssh_dispatch_run_fatal: Connection to UNKNOWN port 65535: Broken pipe",
        """
        channel 0: open failed: administratively prohibited: open failed
        Connection closed by UNKNOWN port 65535
        """,
    ])
    func leavesGenericProxyTransportClosureUnclassified(_ diagnostic: String) throws {
        let result = try run("printf '%s\\n' '\(diagnostic)' >&2; exit 255")

        #expect(result.status == 252)
        for line in diagnostic.split(separator: "\n") {
            #expect(result.stderr.contains(String(line)))
        }
        #expect(result.temporaryFiles.isEmpty)
    }

    @Test func independentTransportDiagnosticMakesProxyClosureRetryable() throws {
        let result = try run(
            """
            printf '%s\\n' 'connect failed: Connection refused' >&2
            printf '%s\\n' 'Connection closed by UNKNOWN port 65535' >&2
            exit 255
            """
        )

        #expect(result.status == 254)
        #expect(result.stderr.contains("Connection refused"))
        #expect(result.stderr.contains("Connection closed by UNKNOWN port 65535"))
        #expect(result.temporaryFiles.isEmpty)
    }

    @Test(arguments: [
        "Warning: Identity file /tmp/missing-key not accessible: No such file or directory.",
        "debug1: load_hostkeys: fopen /tmp/missing-known-hosts: No such file or directory",
        "Warning: Identity file /tmp/unreadable-key not accessible: Permission denied.",
        "debug1: load_hostkeys: fopen /tmp/unreadable-known-hosts: Permission denied",
    ])
    func nonFatalMissingFileDiagnosticDoesNotOverrideTransportFailure(_ diagnostic: String) throws {
        let result = try run(
            """
            printf '%s\\n' '\(diagnostic)' >&2
            printf '%s\\n' 'ssh: connect to host example.test port 22: Network is unreachable' >&2
            exit 255
            """
        )

        #expect(result.status == 254)
        #expect(result.stderr.contains(diagnostic))
        #expect(result.stderr.contains("Network is unreachable"))
        #expect(result.temporaryFiles.isEmpty)
    }

    @Test(arguments: [
        "kex_exchange_identification: Connection closed by remote host",
        "Connection closed by 192.0.2.1 port 22",
    ])
    func mapsConnectionClosedStartupFailureToRetryableStatus(_ diagnostic: String) throws {
        let result = try run("printf '%s\\n' '\(diagnostic)' >&2; exit 255")

        #expect(result.status == 254)
        #expect(result.stderr.contains(diagnostic))
        #expect(result.temporaryFiles.isEmpty)
    }

    @Test func preservesTerminalStderrForInteractiveAuthenticationHelpers() throws {
        let result = try run(
            """
            if ! test -t 2; then
              printf '%s\\n' 'authentication helper requires a terminal' >&2
              exit 255
            fi
            printf '%s\\n' 'ssh: connect to host example.test port 22: Network is unreachable' >&2
            exit 255
            """
        )

        #expect(result.status == 254)
        #expect(result.stderr.contains("Network is unreachable"))
        #expect(!result.stderr.contains("authentication helper requires a terminal"))
        #expect(result.temporaryFiles.isEmpty)
    }

    @Test(arguments: [
        "zsh: command not found: corp-proxy",
        "zsh:1: no such file or directory: /opt/corp/proxy",
        "bash: line 1: /opt/corp/proxy: No such file or directory",
    ])
    func proxyConfigurationFailureTakesPrecedenceOverGenericTransportMarker(
        _ diagnostic: String
    ) throws {
        let result = try run(
            """
            printf '%s\\n' '\(diagnostic)' >&2
            printf '%s\\n' 'Connection closed by UNKNOWN port 65535' >&2
            exit 255
            """
        )

        #expect(result.status == 255)
        #expect(result.stderr.contains(diagnostic))
        #expect(result.stderr.contains("Connection closed by UNKNOWN port 65535"))
        #expect(result.temporaryFiles.isEmpty)
    }

    @Test func terminatesNestedForegroundAuthenticationProcesses() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("bree-ssh-auth-tree-\(UUID().uuidString)", isDirectory: true)
        let leafScript = root.appendingPathComponent("leaf.sh")
        let leafPIDFile = root.appendingPathComponent("leaf.pid")
        let signalLog = root.appendingPathComponent("signal.log")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try """
        #!/bin/sh
        trap '' HUP INT
        trap 'printf "%s\\n" term > "$BREE_TEST_SIGNAL_LOG"' TERM
        printf '%s\\n' "$$" > "$BREE_TEST_LEAF_PID"
        while :; do /bin/sleep 30; done
        """.write(to: leafScript, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: leafScript.path)

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        ( /bin/sh "$BREE_TEST_LEAF_SCRIPT" & wait $! ) &
        bree_test_auth_root=$!
        bree_test_ready_attempt=0
        while [ ! -s "$BREE_TEST_LEAF_PID" ] && [ "$bree_test_ready_attempt" -lt 300 ]; do
          /bin/sleep 0.01
          bree_test_ready_attempt=$((bree_test_ready_attempt + 1))
        done
        test -s "$BREE_TEST_LEAF_PID" || exit 98
        bree_ssh_terminate_auth_process_tree "$bree_test_auth_root" "$$"
        wait "$bree_test_auth_root" 2>/dev/null || true
        test "$(/bin/cat "$BREE_TEST_SIGNAL_LOG" 2>/dev/null || true)" = term
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "BREE_TEST_LEAF_SCRIPT": leafScript.path,
            "BREE_TEST_LEAF_PID": leafPIDFile.path,
            "BREE_TEST_SIGNAL_LOG": signalLog.path,
        ]) { _, override in override }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderrCapture = try makeStandardErrorCapture()
        defer { removeStandardErrorCapture(stderrCapture) }
        process.standardError = stderrCapture.handle

        try process.run()
        try waitForExit(process, stderrCapture: stderrCapture)

        let leafPID = try #require(Int32(
            String(contentsOf: leafPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        defer { Darwin.kill(leafPID, SIGKILL) }
        waitForProcessesToExit([leafPID])

        #expect(process.terminationStatus == 0)
        #expect(try String(contentsOf: signalLog, encoding: .utf8) == "term\n")
        #expect(processLiveness(leafPID) == false)
        #expect(processLiveness(leafPID) != nil)
    }

    @Test func terminatesTreeWhenAuthenticationRootWasAlreadyStopped() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("bree-ssh-auth-prestopped-\(UUID().uuidString)", isDirectory: true)
        let leafScript = root.appendingPathComponent("leaf.sh")
        let leafPIDFile = root.appendingPathComponent("leaf.pid")
        let readyMarker = root.appendingPathComponent("ready")
        let signalLog = root.appendingPathComponent("signal.log")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try """
        #!/bin/sh
        trap '' HUP INT
        trap 'printf "%s\\n" term > "$BREE_TEST_SIGNAL_LOG"' TERM
        printf '%s\\n' "$$" > "$BREE_TEST_LEAF_PID"
        : > "$BREE_TEST_READY_MARKER"
        while :; do /bin/sleep 30; done
        """.write(to: leafScript, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: leafScript.path)

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        ( /bin/sh "$BREE_TEST_LEAF_SCRIPT" & wait $! ) &
        bree_test_auth_root=$!
        trap 'kill -CONT "$bree_test_auth_root" >/dev/null 2>&1 || true; kill -KILL "$bree_test_auth_root" >/dev/null 2>&1 || true' EXIT
        bree_test_ready_attempt=0
        while [ ! -f "$BREE_TEST_READY_MARKER" ] && [ "$bree_test_ready_attempt" -lt 300 ]; do
          /bin/sleep 0.01
          bree_test_ready_attempt=$((bree_test_ready_attempt + 1))
        done
        test -f "$BREE_TEST_READY_MARKER" || exit 98
        # The root is already stopped before cleanup takes ownership. The
        # helper must journal it without sending a second STOP, then terminate
        # both the root and its foreground-auth child.
        /bin/kill -STOP "$bree_test_auth_root"
        bree_ssh_terminate_auth_process_tree "$bree_test_auth_root" "$$"
        wait "$bree_test_auth_root" 2>/dev/null || true
        test "$(/bin/cat "$BREE_TEST_SIGNAL_LOG" 2>/dev/null || true)" = term
        trap - EXIT
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "BREE_TEST_LEAF_SCRIPT": leafScript.path,
            "BREE_TEST_LEAF_PID": leafPIDFile.path,
            "BREE_TEST_READY_MARKER": readyMarker.path,
            "BREE_TEST_SIGNAL_LOG": signalLog.path,
        ]) { _, override in override }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderrCapture = try makeStandardErrorCapture()
        defer { removeStandardErrorCapture(stderrCapture) }
        process.standardError = stderrCapture.handle

        try process.run()
        try waitForExit(process, stderrCapture: stderrCapture)

        let leafPID = try #require(Int32(
            String(contentsOf: leafPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        defer { Darwin.kill(leafPID, SIGKILL) }
        waitForProcessesToExit([leafPID])

        #expect(process.terminationStatus == 0)
        #expect(try String(contentsOf: signalLog, encoding: .utf8) == "term\n")
        #expect(processLiveness(leafPID) == false)
        #expect(processLiveness(leafPID) != nil)
    }

    @Test func refusesAuthenticationRootWithMismatchedKnownParent() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("bree-ssh-auth-root-parent-\(UUID().uuidString)", isDirectory: true)
        let readyMarker = root.appendingPathComponent("ready")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        ( trap '' HUP INT TERM; : > "$BREE_TEST_READY_MARKER"; while :; do /bin/sleep 30; done ) &
        bree_test_auth_root=$!
        trap '/bin/kill -KILL "$bree_test_auth_root" >/dev/null 2>&1 || true' EXIT
        bree_test_ready_attempt=0
        while [ ! -f "$BREE_TEST_READY_MARKER" ] && [ "$bree_test_ready_attempt" -lt 300 ]; do
          /bin/sleep 0.01
          bree_test_ready_attempt=$((bree_test_ready_attempt + 1))
        done
        test -f "$BREE_TEST_READY_MARKER" || exit 98
        bree_ssh_terminate_auth_process_tree "$bree_test_auth_root" 1
        /bin/kill -0 "$bree_test_auth_root" >/dev/null 2>&1 || exit 97
        /bin/kill -KILL "$bree_test_auth_root" >/dev/null 2>&1 || true
        wait "$bree_test_auth_root" 2>/dev/null || true
        trap - EXIT
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "BREE_TEST_READY_MARKER": readyMarker.path,
        ]) { _, override in override }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderrCapture = try makeStandardErrorCapture()
        defer { removeStandardErrorCapture(stderrCapture) }
        process.standardError = stderrCapture.handle

        try process.run()
        try waitForExit(process, stderrCapture: stderrCapture)

        #expect(process.terminationStatus == 0)
    }

    @Test func processTreeTerminationUsesOneOverallDeadline() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("bree-ssh-auth-deadline-\(UUID().uuidString)", isDirectory: true)
        let chainScript = root.appendingPathComponent("chain.sh")
        let setIDLauncher = root.appendingPathComponent("setid-launcher.pl")
        let readyMarker = root.appendingPathComponent("ready")
        let cleanupStartedMarker = root.appendingPathComponent("cleanup-started")
        let pidLog = root.appendingPathComponent("pids")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try """
        #!/bin/sh
        trap '' HUP INT TERM
        printf '%s\\n' "$$" >> "$BREE_TEST_PID_LOG"
        bree_test_depth="${BREE_TEST_CHAIN_DEPTH:-0}"
        if [ "$bree_test_depth" -gt 0 ]; then
          BREE_TEST_CHAIN_DEPTH=$((bree_test_depth - 1)) /bin/sh "$0" &
        else
          : > "$BREE_TEST_READY_MARKER"
        fi
        while :; do /bin/sleep 30; done
        """.write(to: chainScript, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: chainScript.path)
        // Keep the synthetic authentication tree in its own session/process
        // group. When a fork-starved cleanup stops members and then kills them,
        // Darwin may send SIGHUP to an orphaned stopped group; that signal must
        // not reach this test's harness shell, which is a sibling of the tree.
        try """
        #!/usr/bin/perl
        use POSIX qw(setsid);
        setsid() or exit 125;
        exec @ARGV or exit 126;
        """.write(to: setIDLauncher, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: setIDLauncher.path)
        defer {
            let processIDs = (try? String(contentsOf: pidLog, encoding: .utf8))?
                .split(separator: "\n")
                .compactMap { Int32($0) } ?? []
            for processID in processIDs {
                Darwin.kill(processID, SIGKILL)
            }
        }

        let command = """
        # The fixture shares a process group with this harness. Ignore the
        # group-delivered signals from the intentionally terminated tree so
        # the harness can finish reporting cleanup assertions.
        trap '' HUP INT TERM
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        BREE_TEST_CHAIN_DEPTH=24 /usr/bin/perl "$BREE_TEST_SETID_LAUNCHER" /bin/sh "$BREE_TEST_CHAIN_SCRIPT" &
        bree_test_auth_root=$!
        bree_test_ready_attempt=0
        while [ ! -f "$BREE_TEST_READY_MARKER" ] && [ "$bree_test_ready_attempt" -lt 300 ]; do
          /bin/sleep 0.01
          bree_test_ready_attempt=$((bree_test_ready_attempt + 1))
        done
        test -f "$BREE_TEST_READY_MARKER" || exit 98
        # Lower the helper shell's process ceiling only after the full fixture
        # exists, so the cleanup runs under process pressure.
        #
        # The kernel charges RLIMIT_NPROC to the real user ID. Count by
        # `ruid`, not `uid`: setuid-root processes the user started, such as
        # the /usr/bin/login that every Terminal or bree tab runs, report
        # uid 0 but still count against this user's ceiling. Counting by
        # effective uid put the ceiling below the live count on hosts with
        # open terminals, so the harness could not fork the helper at all.
        #
        # The budget is explicit. The helper forks one command at a time and
        # uses no pipelines or background jobs, so it needs at most three
        # process slots at once: its subshell, a command-substitution child
        # and the command that child runs. The remaining slots absorb other
        # processes this user starts while cleanup runs. The count also
        # includes the command substitution, ps and awk that take it; they
        # exit before cleanup starts.
        bree_test_helper_process_slots=3
        bree_test_concurrent_activity_slots=13
        bree_test_user_id=$(/usr/bin/id -u 2>/dev/null || true)
        bree_test_process_count=$(
          /bin/ps -axo ruid= 2>/dev/null |
            /usr/bin/awk -v uid="$bree_test_user_id" '$1 == uid { count += 1 } END { print count + 0 }'
        ) || bree_test_process_count=
        case "$bree_test_process_count" in
          ''|0|*[!0-9]*)
            printf '%s\n' "could not count processes for uid $bree_test_user_id" >&2
            exit 97
            ;;
        esac
        ulimit -u "$((bree_test_process_count + bree_test_helper_process_slots + bree_test_concurrent_activity_slots))" || exit 96
        : > "$BREE_TEST_CLEANUP_STARTED_MARKER"
        # Exercise the event-enabled path without publishing an event. The
        # helper must reserve a force pass instead of rolling back after the
        # bounded FIFO wait.
        bree_ssh_terminate_auth_process_tree "$bree_test_auth_root" "$$" 1
        bree_test_cleanup_status=$?
        if [ "$bree_test_cleanup_status" -ne 0 ]; then
          # Report the helper failure instead of waiting on a root it never
          # signalled.
          printf '%s\n' "cleanup helper exited with status $bree_test_cleanup_status" >&2
          exit "$bree_test_cleanup_status"
        fi
        wait "$bree_test_auth_root" 2>/dev/null || true
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "BREE_TEST_CHAIN_SCRIPT": chainScript.path,
            "BREE_TEST_SETID_LAUNCHER": setIDLauncher.path,
            "BREE_TEST_CLEANUP_STARTED_MARKER": cleanupStartedMarker.path,
            "BREE_TEST_READY_MARKER": readyMarker.path,
            "BREE_TEST_PID_LOG": pidLog.path,
        ]) { _, override in override }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderrCapture = try makeStandardErrorCapture()
        defer { removeStandardErrorCapture(stderrCapture) }
        process.standardError = stderrCapture.handle

        try process.run()
        // Process launch and fixture readiness are outside the cleanup
        // contract. Start the wall-clock assertion at the helper boundary so
        // scheduler and app-host startup latency cannot consume it.
        let startDeadline = Date.now.addingTimeInterval(5)
        while !fileManager.fileExists(atPath: cleanupStartedMarker.path),
              process.isRunning,
              Date.now < startDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        try #require(fileManager.fileExists(atPath: cleanupStartedMarker.path))
        let startedAt = Date.now
        try waitForExit(process, stderrCapture: stderrCapture, timeout: 20)
        let elapsed = Date.now.timeIntervalSince(startedAt)

        let processIDs = try String(contentsOf: pidLog, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { Int32($0) }
        waitForProcessesToExit(processIDs, timeout: 10)

        try? stderrCapture.handle.synchronize()
        let cleanupStderr = (try? String(contentsOf: stderrCapture.url, encoding: .utf8)) ?? ""
        #expect(
            process.terminationStatus == 0,
            "Cleanup shell terminated with reason=\(process.terminationReason.rawValue) status=\(process.terminationStatus); stderr=\(cleanupStderr)"
        )
        #expect(processIDs.count == 25)
        // The helper has one shared two-second discovery budget plus a bounded
        // force pass. Process-table scans can be slow on a loaded macOS host,
        // so allow bounded cleanup overhead while still rejecting the old
        // one-deadline-per-node behavior.
        #expect(
            elapsed < 15,
            "Foreground authentication cleanup took \(elapsed) seconds instead of one bounded deadline"
        )
        let processStates = processIDs.map(processLiveness)
        #expect(!processStates.contains(where: { $0 == nil }))
        #expect(!processStates.contains(where: { $0 == true }))
    }

    @Test func terminatesReplacementSpawnedByAuthenticationTermHandler() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("bree-ssh-auth-replacement-\(UUID().uuidString)", isDirectory: true)
        let readyMarker = root.appendingPathComponent("ready")
        let replacementScript = root.appendingPathComponent("replacement.sh")
        let delayedLauncher = root.appendingPathComponent("delayed-launcher.sh")
        let setIDLauncher = root.appendingPathComponent("setid-launcher.pl")
        let replacementPIDFile = root.appendingPathComponent("replacement.pid")
        let handlerDone = root.appendingPathComponent("handler.done")
        let eventToken = UUID().uuidString.lowercased()
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try """
        #!/bin/sh
        trap '' HUP INT TERM
        printf '%s\\n' "$$" > "$BREE_TEST_REPLACEMENT_PID"
        while :; do /bin/sleep 30; done
        """.write(to: replacementScript, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: replacementScript.path)
        try """
        #!/bin/sh
        trap '' HUP INT TERM
        # Keep the replacement behind the first one-second FIFO read. The
        # helper must retry the completion event through its bounded deadline
        # before releasing the wrapper and discovering the detached child.
        /bin/sleep 1.2
        /bin/sh "$BREE_TEST_REPLACEMENT_SCRIPT" &
        printf '%s\\n' "$!" > "$BREE_TEST_REPLACEMENT_PID"
        : > "$BREE_TEST_HANDLER_DONE"
        """.write(to: delayedLauncher, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: delayedLauncher.path)
        try """
        #!/usr/bin/perl
        use POSIX qw(setsid);
        setsid() or exit 125;
        exec @ARGV or exit 126;
        """.write(to: setIDLauncher, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: setIDLauncher.path)

        let policy = SSHForegroundAuthenticationRetryPolicy()
        let classifiedAuthentication = policy.classifyingTransientFailure(
            in: """
            # Delay a detached replacement and wait for its completion marker.
            # The cleanup handshake must wait for this handler before the
            # parent can disappear and reparent the replacement.
            trap 'trap "" TERM; /usr/bin/perl "$BREE_TEST_SETID_LAUNCHER" /bin/sh "$BREE_TEST_DELAYED_LAUNCHER" </dev/null >/dev/null 2>&1 & while [ ! -f "$BREE_TEST_HANDLER_DONE" ]; do /bin/sleep 0.01; done; exit 143' TERM
            : > "$BREE_TEST_READY_MARKER"
            while :; do /bin/sleep 30; done
            """
        )
        let command = """
        \(policy.processTreeTerminationShellFunction())
        BREE_SSH_AUTH_EVENT_TOKEN=\(eventToken); export BREE_SSH_AUTH_EVENT_TOKEN
        ( \(classifiedAuthentication) ) &
        bree_test_auth_root=$!
        bree_test_ready_attempt=0
        while [ ! -f "$BREE_TEST_READY_MARKER" ] && [ "$bree_test_ready_attempt" -lt 300 ]; do
          /bin/sleep 0.01
          bree_test_ready_attempt=$((bree_test_ready_attempt + 1))
        done
        test -f "$BREE_TEST_READY_MARKER" || exit 98
        bree_ssh_terminate_auth_process_tree "$bree_test_auth_root" "$$" 1 "\(eventToken)"
        wait "$bree_test_auth_root" 2>/dev/null || true
        bree_test_replacement_attempt=0
        while [ ! -s "$BREE_TEST_REPLACEMENT_PID" ] && [ "$bree_test_replacement_attempt" -lt 100 ]; do
          /bin/sleep 0.01
          bree_test_replacement_attempt=$((bree_test_replacement_attempt + 1))
        done
        test -s "$BREE_TEST_REPLACEMENT_PID"
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "BREE_TEST_READY_MARKER": readyMarker.path,
            "BREE_TEST_SETID_LAUNCHER": setIDLauncher.path,
            "BREE_TEST_DELAYED_LAUNCHER": delayedLauncher.path,
            "BREE_TEST_HANDLER_DONE": handlerDone.path,
            "BREE_TEST_REPLACEMENT_SCRIPT": replacementScript.path,
            "BREE_TEST_REPLACEMENT_PID": replacementPIDFile.path,
        ]) { _, override in override }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderrCapture = try makeStandardErrorCapture()
        defer { removeStandardErrorCapture(stderrCapture) }
        process.standardError = stderrCapture.handle

        try process.run()
        try waitForExit(process, stderrCapture: stderrCapture)

        let replacementPID = try #require(Int32(
            String(contentsOf: replacementPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        defer { Darwin.kill(replacementPID, SIGKILL) }
        waitForProcessesToExit([replacementPID])

        #expect(process.terminationStatus == 0)
        #expect(processLiveness(replacementPID) == false)
        #expect(processLiveness(replacementPID) != nil)
    }

    @Test func restoresTerminalModesWhenTerminatingForegroundAuthenticationTree() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("bree-ssh-auth-termios-\(UUID().uuidString)", isDirectory: true)
        let readyMarker = root.appendingPathComponent("ready")
        let signalLog = root.appendingPathComponent("signal.log")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let policy = SSHForegroundAuthenticationRetryPolicy()
        let classifiedAuthentication = policy.classifyingTransientFailure(
            in: """
            trap '' HUP INT
            trap 'printf "%s\\n" term > "$BREE_TEST_SIGNAL_LOG"; exit 143' TERM
            : > "$BREE_TEST_READY_MARKER"
            while :; do /bin/sleep 30; done
            """
        )
        let command = """
        test -t 0 || exit 96
        bree_test_terminal_mode_before=$(/bin/stty -g) || exit 97
        \(policy.processTreeTerminationShellFunction())
        ( \(classifiedAuthentication) ) &
        bree_test_auth_root=$!
        bree_test_ready_attempt=0
        while [ ! -f "$BREE_TEST_READY_MARKER" ] && [ "$bree_test_ready_attempt" -lt 300 ]; do
          /bin/sleep 0.01
          bree_test_ready_attempt=$((bree_test_ready_attempt + 1))
        done
        test -f "$BREE_TEST_READY_MARKER" || exit 98
        bree_ssh_terminate_auth_process_tree "$bree_test_auth_root" "$$" 1
        wait "$bree_test_auth_root" 2>/dev/null || true
        bree_test_terminal_mode_after=$(/bin/stty -g) || exit 99
        test "$bree_test_terminal_mode_after" = "$bree_test_terminal_mode_before"
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", "/bin/sh", "-c", command]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "BREE_TEST_READY_MARKER": readyMarker.path,
            "BREE_TEST_SIGNAL_LOG": signalLog.path,
        ]) { _, override in override }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderrCapture = try makeStandardErrorCapture()
        defer { removeStandardErrorCapture(stderrCapture) }
        process.standardError = stderrCapture.handle

        try process.run()
        try waitForExit(process, stderrCapture: stderrCapture)

        #expect(process.terminationStatus == 0)
        #expect(try String(contentsOf: signalLog, encoding: .utf8) == "term\n")
    }

    @Test func keepsDiagnosticStateBoundedWhileCommandIsRunning() throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("bree-ssh-auth-policy-bounds-\(UUID().uuidString)", isDirectory: true)
        let readyFile = temporaryDirectory.appendingPathComponent("producer-ready")
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            SSHForegroundAuthenticationRetryPolicy().classifyingTransientFailure(
                in: """
                /usr/bin/head -c 8192 /dev/zero | /usr/bin/tr '\\000' x >&2
                printf 'Network is unreachable' >&2
                /usr/bin/head -c 4096 /dev/zero | /usr/bin/tr '\\000' x >&2
                : > "$BREE_TEST_READY_FILE"
                /bin/sleep 3
                exit 255
                """
            ),
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["TMPDIR"] = temporaryDirectory.path
        environment["BREE_TEST_READY_FILE"] = readyFile.path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderrCapture = try makeStandardErrorCapture()
        defer { removeStandardErrorCapture(stderrCapture) }
        process.standardError = stderrCapture.handle

        try process.run()
        defer {
            terminateIfRunning(process)
            try? fileManager.removeItem(at: temporaryDirectory)
        }

        let deadline = Date.now.addingTimeInterval(10)
        while !fileManager.fileExists(atPath: readyFile.path), process.isRunning, Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(fileManager.fileExists(atPath: readyFile.path))

        let diagnosticFiles = try fileManager.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: []
        ).filter {
            $0 != readyFile
                && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        let largestDiagnosticFile = try diagnosticFiles
            .map { try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 }
            .max() ?? 0

        #expect(
            largestDiagnosticFile <= 64,
            "Foreground authentication must not retain unbounded remote-controlled stderr"
        )
        let classificationDeadline = Date.now.addingTimeInterval(5)
        var classifiedWhileRunning = false
        var lastClassifications: [String] = []
        while process.isRunning, Date.now < classificationDeadline {
            lastClassifications = diagnosticFiles.compactMap {
                try? String(contentsOf: $0, encoding: .utf8)
            }
            if lastClassifications.contains("transient\n") {
                classifiedWhileRunning = true
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(
            classifiedWhileRunning,
            "A newline-free stderr stream must be classified incrementally with bounded records; observed \(lastClassifications)"
        )
        try waitForExit(process, stderrCapture: stderrCapture)
        #expect(process.terminationStatus == 254)
    }

    func run(_ command: String, authEventToken: String? = nil) throws -> (
        status: Int32,
        stderr: String,
        temporaryFiles: [String]
    ) {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("bree-ssh-auth-policy-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let process = Process()
        let stderrCapture = try makeStandardErrorCapture()
        defer { removeStandardErrorCapture(stderrCapture) }
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            SSHForegroundAuthenticationRetryPolicy().classifyingTransientFailure(in: command),
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["TMPDIR"] = temporaryDirectory.path
        environment["BREE_SSH_AUTH_EVENT_TOKEN"] = authEventToken
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrCapture.handle

        try process.run()
        try waitForExit(process, stderrCapture: stderrCapture)
        try stderrCapture.handle.close()
        let stderrData = try Data(contentsOf: stderrCapture.url)
        let temporaryFiles = try fileManager.contentsOfDirectory(atPath: temporaryDirectory.path)
        return (
            process.terminationStatus,
            String(data: stderrData, encoding: .utf8) ?? "",
            temporaryFiles
        )
    }

    private func makeStandardErrorCapture() throws -> (url: URL, handle: FileHandle) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bree-ssh-auth-stderr-\(UUID().uuidString).log")
        try Data().write(to: url, options: .atomic)
        return (
            url: url,
            handle: try FileHandle(forWritingTo: url)
        )
    }

    private func removeStandardErrorCapture(_ capture: (url: URL, handle: FileHandle)) {
        try? capture.handle.close()
        try? FileManager.default.removeItem(at: capture.url)
    }

    private func waitForExit(
        _ process: Process,
        stderrCapture: (url: URL, handle: FileHandle),
        timeout: TimeInterval = 10
    ) throws {
        let deadline = Date.now.addingTimeInterval(timeout)
        while process.isRunning, Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        let timedOut = process.isRunning
        if timedOut {
            terminateIfRunning(process)
        }
        try? stderrCapture.handle.synchronize()
        let stderr = (try? String(contentsOf: stderrCapture.url, encoding: .utf8)) ?? ""
        try #require(
            !timedOut,
            "Process timed out after \(timeout) seconds; stderr: \(stderr)"
        )
    }

    private func terminateIfRunning(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()

        var deadline = Date.now.addingTimeInterval(1)
        while process.isRunning, Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            deadline = Date.now.addingTimeInterval(1)
            while process.isRunning, Date.now < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
    }

    private func processLiveness(_ processID: Int32) -> Bool? {
        // kill(pid, 0) also succeeds for zombies. The cleanup helper treats a
        // zombie as terminated, so inspect process state before reporting a
        // survivor. An unexpected proc_pidinfo result is unknown, not proof of
        // termination.
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        let size = proc_pidinfo(
            pid_t(processID),
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(expectedSize)
        )
        if Int(size) == expectedSize {
            return info.pbi_status == UInt32(SZOMB) ? false : true
        }
        // proc_pidinfo reports either zero or -1 with ESRCH after a process
        // has been reaped. Both results mean the process is no longer live.
        if (size == 0 || size < 0) && errno == ESRCH {
            return false
        }
        return nil
    }

    /// Wait for process exit or zombie reaping after the helper returns. This
    /// scheduler-only allowance is separate from the helper's measured cleanup
    /// deadline and prevents a loaded runner from making liveness assertions
    /// race delayed reaping.
    private func waitForProcessesToExit(_ processIDs: [Int32], timeout: TimeInterval = 5) {
        let deadline = Date.now.addingTimeInterval(timeout)
        while processIDs.contains(where: { processLiveness($0) == true }), Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}
