#!/usr/bin/env python3
"""Regression tests for CLI socket autodiscovery."""

from __future__ import annotations

import glob
import os
import plistlib
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

from claude_teams_test_utils import FIXTURE_SOCKET_PASSWORD, accept_fixture_socket_authentication


def resolve_bree_cli() -> str:
    explicit = os.environ.get("BREE_CLI_BIN") or os.environ.get("BREE_CLI")
    if explicit and os.path.exists(explicit) and os.access(explicit, os.X_OK):
        return explicit

    candidates: list[str] = []
    candidates.extend(glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/bree")))
    candidates.extend(glob.glob("/tmp/bree-*/Build/Products/Debug/bree"))
    candidates = [p for p in candidates if os.path.exists(p) and os.access(p, os.X_OK)]
    if candidates:
        candidates.sort(key=os.path.getmtime, reverse=True)
        return candidates[0]

    in_path = shutil.which("bree")
    if in_path:
        return in_path

    raise RuntimeError("Unable to find bree CLI binary. Set BREE_CLI_BIN.")


class PingServer:
    def __init__(
        self,
        socket_path: str,
        response: bytes = b"PONG\n",
        accept_timeout: float = 6.0,
    ):
        self.socket_path = socket_path
        self.response = response
        self.accept_timeout = accept_timeout
        self.ready = threading.Event()
        self._done = threading.Event()
        self.error: Exception | None = None
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._connection_threads: list[threading.Thread] = []

    def start(self) -> None:
        self._thread.start()

    def wait_ready(self, timeout: float) -> bool:
        return self.ready.wait(timeout)

    def join(self, timeout: float) -> None:
        self._thread.join(timeout=timeout)

    def _run(self) -> None:
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            if os.path.exists(self.socket_path):
                os.remove(self.socket_path)
            server.bind(self.socket_path)
            server.listen(8)
            self.ready.set()

            # The CLI may probe candidate sockets with a connect-only check before
            # issuing the actual command, so keep accepting until the ping arrives
            # or the test socket times out.
            deadline = time.monotonic() + self.accept_timeout
            while not self._done.is_set():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return
                server.settimeout(min(0.2, remaining))
                try:
                    conn, _ = server.accept()
                # GitHub's macOS Python can report socket polling timeouts as
                # socket.timeout rather than built-in TimeoutError.
                except (socket.timeout, TimeoutError):
                    continue
                connection_thread = threading.Thread(
                    target=self._handle_connection,
                    args=(conn,),
                    daemon=True,
                )
                self._connection_threads.append(connection_thread)
                connection_thread.start()
        except Exception as exc:  # pragma: no cover - explicit surface on failure
            self.error = exc
            self.ready.set()
        finally:
            self._done.set()
            server.close()
            for connection_thread in self._connection_threads:
                connection_thread.join(timeout=1.0)

    def _handle_connection(self, conn: socket.socket) -> None:
        with conn:
            conn.settimeout(2.0)
            try:
                with conn.makefile("rwb") as stream:
                    for data in stream:
                        if accept_fixture_socket_authentication(data, stream):
                            continue
                        if b"ping" in data:
                            stream.write(self.response)
                            stream.flush()
                            self._done.set()
                        return
            except (ConnectionResetError, socket.timeout, TimeoutError):
                return


def write_marker(home: str, marker_name: str, socket_path: str) -> None:
    app_support = os.path.join(home, ".local", "state", "bree")
    os.makedirs(app_support, exist_ok=True)
    with open(os.path.join(app_support, marker_name), "w", encoding="utf-8") as f:
        f.write(f"{socket_path}\n")


def temporary_socket_home(prefix: str) -> tempfile.TemporaryDirectory:
    # Darwin caps Unix socket paths at a little over 100 bytes. Keep fake HOME
    # roots short because stable sockets live under ~/.local/state/bree.
    return tempfile.TemporaryDirectory(prefix=prefix, dir="/tmp")


def copy_runtime_frameworks(cli_path: str, fixture_contents: str) -> None:
    frameworks_dir = os.path.join(fixture_contents, "Frameworks")
    os.makedirs(frameworks_dir, exist_ok=True)

    search_roots: list[str] = []
    current = os.path.dirname(cli_path)
    for _ in range(4):
        search_roots.append(os.path.join(current, "Frameworks"))
        search_roots.append(os.path.join(current, "PackageFrameworks"))
        parent = os.path.dirname(current)
        if parent == current:
            break
        current = parent

    for search_root in search_roots:
        if not os.path.isdir(search_root):
            continue
        for framework_name in sorted(os.listdir(search_root)):
            if not framework_name.endswith(".framework"):
                continue
            source = os.path.join(search_root, framework_name)
            destination = os.path.join(frameworks_dir, framework_name)
            if os.path.isdir(source) and not os.path.exists(destination):
                shutil.copytree(source, destination, symlinks=True)


def bundled_cli_for_variant(cli_path: str, root: str, app_name: str, bundle_id: str) -> str:
    app_dir = os.path.join(root, f"{app_name}.app")
    contents_dir = os.path.join(app_dir, "Contents")
    bin_dir = os.path.join(app_dir, "Contents", "Resources", "bin")
    os.makedirs(bin_dir, exist_ok=True)
    bundled_cli = os.path.join(bin_dir, "bree")
    shutil.copy2(cli_path, bundled_cli)
    os.chmod(bundled_cli, 0o755)
    copy_runtime_frameworks(cli_path, contents_dir)

    plist_path = os.path.join(contents_dir, "Info.plist")
    os.makedirs(os.path.dirname(plist_path), exist_ok=True)
    with open(plist_path, "wb") as f:
        plistlib.dump(
            {
                "CFBundleIdentifier": bundle_id,
                "CFBundleName": app_name,
                "CFBundleDisplayName": app_name,
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "0.0-test",
                "CFBundleVersion": "1",
            },
            f,
        )
    return bundled_cli


def run_ping(
    cli_path: str,
    home: str,
    extra_env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    for key in list(env):
        if key.startswith("BREE_"):
            env.pop(key, None)
    env["HOME"] = home
    env["CFFIXED_USER_HOME"] = home
    env["BREE_CLI_SENTRY_DISABLED"] = "1"
    env["BREE_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        [cli_path, "--password", FIXTURE_SOCKET_PASSWORD, "ping"],
        text=True,
        capture_output=True,
        env=env,
        timeout=8,
        check=False,
    )


def expect_ping_uses_socket(cli_path: str, home: str, socket_path: str, label: str) -> bool:
    server = PingServer(socket_path)
    server.start()

    if not server.wait_ready(2.0):
        print(f"FAIL: {label} socket server did not become ready")
        return False

    if server.error is not None:
        print(f"FAIL: {label} socket server failed to start: {server.error}")
        return False

    try:
        proc = run_ping(cli_path, home)
    except Exception as exc:
        print(f"FAIL: invoking {label} bree ping failed: {exc}")
        return False
    finally:
        server.join(timeout=2.0)
        try:
            os.remove(socket_path)
        except OSError:
            pass

    if server.error is not None:
        print(f"FAIL: {label} socket server error: {server.error}")
        return False

    if proc.returncode != 0:
        print(f"FAIL: {label} bree ping returned non-zero status")
        print(f"stdout={proc.stdout!r}")
        print(f"stderr={proc.stderr!r}")
        return False

    if proc.stdout.strip() != "PONG":
        print(f"FAIL: {label} bree ping did not use the expected socket")
        print(f"stdout={proc.stdout!r}")
        print(f"stderr={proc.stderr!r}")
        return False

    return True


def expect_ping_ignores_dev_tag(
    cli_path: str,
    home: str,
    expected_socket_path: str,
    rogue_socket_path: str,
    rogue_tag: str,
    label: str,
) -> bool:
    expected_server = PingServer(expected_socket_path)
    rogue_server = PingServer(rogue_socket_path, response=b"WRONG\n")
    expected_server.start()
    rogue_server.start()

    for server_label, server in [
        (label, expected_server),
        ("rogue dev", rogue_server),
    ]:
        if not server.wait_ready(2.0):
            print(f"FAIL: {server_label} socket server did not become ready")
            return False
        if server.error is not None:
            print(f"FAIL: {server_label} socket server failed to start: {server.error}")
            return False

    try:
        proc = run_ping(cli_path, home, extra_env={"BREE_TAG": rogue_tag})
    except Exception as exc:
        print(f"FAIL: invoking {label} bree ping failed: {exc}")
        return False
    finally:
        expected_server.join(timeout=2.0)
        rogue_server.join(timeout=2.0)
        for path in [expected_socket_path, rogue_socket_path]:
            try:
                os.remove(path)
            except OSError:
                pass

    if proc.returncode != 0:
        print(f"FAIL: {label} bree ping returned non-zero status")
        print(f"stdout={proc.stdout!r}")
        print(f"stderr={proc.stderr!r}")
        return False

    if proc.stdout.strip() != "PONG":
        print(f"FAIL: {label} bree ping followed BREE_TAG to the rogue dev socket")
        print(f"stdout={proc.stdout!r}")
        print(f"stderr={proc.stderr!r}")
        return False

    return True


def expect_ping_does_not_use_socket(
    cli_path: str,
    home: str,
    socket_path: str,
    label: str,
) -> bool:
    os.makedirs(os.path.dirname(socket_path), exist_ok=True)
    server = PingServer(socket_path, response=b"WRONG\n", accept_timeout=1.0)
    server.start()

    if not server.wait_ready(2.0):
        print(f"FAIL: {label} socket server did not become ready")
        return False

    if server.error is not None:
        print(f"FAIL: {label} socket server failed to start: {server.error}")
        return False

    try:
        proc = run_ping(cli_path, home)
    except Exception as exc:
        print(f"FAIL: invoking {label} bree ping failed unexpectedly: {exc}")
        return False
    finally:
        server.join(timeout=2.0)
        try:
            os.remove(socket_path)
        except OSError:
            pass

    if proc.stdout.strip() == "WRONG":
        print(f"FAIL: {label} bree ping used the stable socket fallback")
        print(f"stdout={proc.stdout!r}")
        print(f"stderr={proc.stderr!r}")
        return False

    return True


def python_client_default_bundle_id(extra_env: dict[str, str]) -> str:
    env = os.environ.copy()
    env.pop("BREE_SOCKET_PATH", None)
    env.pop("BREE_SOCKET", None)
    env.pop("BREE_BUNDLE_ID", None)
    env.pop("BREE_TAG", None)
    env.update(extra_env)

    tests_dir = os.path.dirname(os.path.abspath(__file__))
    python_path = env.get("PYTHONPATH")
    env["PYTHONPATH"] = tests_dir if not python_path else f"{tests_dir}{os.pathsep}{python_path}"

    proc = subprocess.run(
        [sys.executable, "-c", "from bree import bree; print(bree.default_bundle_id())"],
        text=True,
        capture_output=True,
        env=env,
        timeout=8,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"bree.py bundle resolution failed: {proc.stderr!r}")
    return proc.stdout.strip()


def python_client_default_socket_path(extra_env: dict[str, str]) -> str:
    env = os.environ.copy()
    env.pop("BREE_SOCKET_PATH", None)
    env.pop("BREE_SOCKET", None)
    env.pop("BREE_BUNDLE_ID", None)
    env.pop("BREE_TAG", None)
    env.update(extra_env)

    tests_dir = os.path.dirname(os.path.abspath(__file__))
    python_path = env.get("PYTHONPATH")
    env["PYTHONPATH"] = tests_dir if not python_path else f"{tests_dir}{os.pathsep}{python_path}"

    proc = subprocess.run(
        [sys.executable, "-c", "from bree import bree; print(bree.default_socket_path())"],
        text=True,
        capture_output=True,
        env=env,
        timeout=8,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"bree.py socket resolution failed: {proc.stderr!r}")
    return proc.stdout.strip()


def test_python_client_ignores_unknown_bundle_env() -> bool:
    expected_tagged_debug = "com.bree.app.debug.variant.test.tag"
    actual = python_client_default_bundle_id({
        "BREE_BUNDLE_ID": "com.example.stale.bundle",
        "BREE_TAG": "variant-test-tag",
    })
    if actual != expected_tagged_debug:
        print("FAIL: python client trusted unknown BREE_BUNDLE_ID over BREE_TAG")
        print(f"expected={expected_tagged_debug!r}")
        print(f"actual={actual!r}")
        return False

    actual = python_client_default_bundle_id({
        "BREE_BUNDLE_ID": "com.bree.app",
        "BREE_TAG": "rogue-stable-tag",
    })
    if actual != "com.bree.app":
        print("FAIL: python client rejected known stable BREE_BUNDLE_ID")
        print(f"actual={actual!r}")
        return False

    print("PASS: python client ignores unknown BREE_BUNDLE_ID values")
    return True


def test_python_client_treats_stable_override_as_implicit() -> bool:
    tag = f"python-stale-stable-{os.getpid()}"
    expected_socket = f"/tmp/bree-debug-{tag}.sock"

    with temporary_socket_home("bree-py-") as home:
        app_support = os.path.join(home, ".local", "state", "bree")
        os.makedirs(app_support, exist_ok=True)
        stable_socket = os.path.join(app_support, "bree.sock")

        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            if os.path.exists(stable_socket):
                os.remove(stable_socket)
            server.bind(stable_socket)
            server.listen(1)

            actual = python_client_default_socket_path({
                "HOME": home,
                "CFFIXED_USER_HOME": home,
                "BREE_SOCKET_PATH": stable_socket,
                "BREE_TAG": tag,
            })
        finally:
            server.close()
            try:
                os.remove(stable_socket)
            except OSError:
                pass

    if actual != expected_socket:
        print("FAIL: python client followed a stale stable BREE_SOCKET_PATH")
        print(f"expected={expected_socket!r}")
        print(f"actual={actual!r}")
        return False

    print("PASS: python client treats stable socket overrides as implicit for tagged debug")
    return True


def test_variant_last_socket_markers(cli_path: str) -> bool:
    pid = os.getpid()
    nightly_slug = f"issue3542-nightly-{pid}"
    dev_agent_slug = f"issue3542-dev-agent-{pid}"
    isolated_nightly_slug = f"issue3542-isolated-nightly-{pid}"
    stable_socket = f"/tmp/bree-issue3542-stable-{pid}.sock"
    nightly_socket = f"/tmp/bree-issue3542-nightly-{pid}.sock"
    dev_agent_socket = f"/tmp/bree-issue3542-dev-agent-{pid}.sock"
    rogue_stable_socket = f"/tmp/bree-debug-rogue-stable-{pid}.sock"
    rogue_stable_tag = f"rogue-stable-{pid}"
    rogue_nightly_socket = f"/tmp/bree-debug-rogue-nightly-{pid}.sock"
    rogue_nightly_tag = f"rogue-nightly-{pid}"
    rogue_dev_agent_socket = f"/tmp/bree-debug-rogue-dev-agent-{pid}.sock"
    rogue_dev_agent_tag = f"rogue-dev-agent-{pid}"

    with temporary_socket_home("bree-home-") as home, \
            tempfile.TemporaryDirectory(prefix="bree-cli-variant-apps-") as apps:
        stable_cli = bundled_cli_for_variant(
            cli_path,
            apps,
            "bree",
            "com.bree.app",
        )
        nightly_cli = bundled_cli_for_variant(
            cli_path,
            apps,
            "bree NIGHTLY",
            f"com.bree.app.nightly.{nightly_slug}",
        )
        isolated_nightly_cli = bundled_cli_for_variant(
            cli_path,
            apps,
            "bree NIGHTLY issue3542",
            f"com.bree.app.nightly.{isolated_nightly_slug}",
        )
        dev_agent_cli = bundled_cli_for_variant(
            cli_path,
            apps,
            "Bree Dev agent",
            f"com.bree.app.debug.{dev_agent_slug}",
        )

        write_marker(home, "last-socket-path", stable_socket)
        write_marker(home, f"nightly-{nightly_slug}-last-socket-path", nightly_socket)
        write_marker(home, f"dev-{dev_agent_slug}-last-socket-path", dev_agent_socket)

        try:
            if not expect_ping_uses_socket(stable_cli, home, stable_socket, "stable"):
                return False
            if not expect_ping_uses_socket(nightly_cli, home, nightly_socket, "nightly"):
                return False
            if not expect_ping_uses_socket(dev_agent_cli, home, dev_agent_socket, "dev-agent"):
                return False
            if not expect_ping_ignores_dev_tag(
                stable_cli,
                home,
                stable_socket,
                rogue_stable_socket,
                rogue_stable_tag,
                "stable with stray BREE_TAG",
            ):
                return False
            if not expect_ping_ignores_dev_tag(
                nightly_cli,
                home,
                nightly_socket,
                rogue_nightly_socket,
                rogue_nightly_tag,
                "nightly with stray BREE_TAG",
            ):
                return False
            if not expect_ping_ignores_dev_tag(
                dev_agent_cli,
                home,
                dev_agent_socket,
                rogue_dev_agent_socket,
                rogue_dev_agent_tag,
                "dev-agent with stray BREE_TAG",
            ):
                return False

            stable_default_socket = os.path.join(
                home,
                ".local",
                "state",
                "bree",
                "bree.sock",
            )
            if not expect_ping_does_not_use_socket(
                isolated_nightly_cli,
                home,
                stable_default_socket,
                "isolated nightly without marker",
            ):
                return False
        finally:
            for path in [
                stable_socket,
                nightly_socket,
                dev_agent_socket,
                rogue_stable_socket,
                rogue_nightly_socket,
                rogue_dev_agent_socket,
            ]:
                try:
                    os.remove(path)
                except OSError:
                    pass

    print("PASS: bundled CLIs read variant-specific socket markers")
    return True


def test_base_debug_cli_discovers_bree_tag(cli_path: str) -> bool:
    tag = f"cli-autodiscover-{os.getpid()}"
    socket_path = f"/tmp/bree-debug-{tag}.sock"
    server = PingServer(socket_path)
    server.start()

    if not server.wait_ready(2.0):
        print("FAIL: socket server did not become ready")
        return False

    if server.error is not None:
        print(f"FAIL: socket server failed to start: {server.error}")
        return False

    try:
        with temporary_socket_home("bree-cli-autodiscover-home-") as home, \
                tempfile.TemporaryDirectory(prefix="bree-cli-base-debug-app-") as apps:
            debug_cli = bundled_cli_for_variant(
                cli_path,
                apps,
                "Bree Dev issue3542",
                "com.bree.app.debug",
            )
            env = os.environ.copy()
            for key in list(env):
                if key.startswith("BREE_"):
                    env.pop(key, None)
            env["HOME"] = home
            env["CFFIXED_USER_HOME"] = home
            # BREE_SOCKET_PATH is an explicit pin for the CLI. Leave it unset
            # here so the base debug bundle derives its tag-scoped default.
            env.pop("BREE_SOCKET_PATH", None)
            env.pop("BREE_SOCKET", None)
            env["BREE_TAG"] = tag
            env["BREE_CLI_SENTRY_DISABLED"] = "1"
            env["BREE_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
            proc = subprocess.run(
                [debug_cli, "ping"],
                text=True,
                capture_output=True,
                env=env,
                timeout=8,
                check=False,
            )
    except Exception as exc:
        print(f"FAIL: invoking bree ping failed: {exc}")
        return False
    finally:
        server.join(timeout=2.0)
        try:
            os.remove(socket_path)
        except OSError:
            pass

    if server.error is not None:
        print(f"FAIL: socket server error: {server.error}")
        return False

    if proc.returncode != 0:
        print("FAIL: bree ping returned non-zero status")
        print(f"stdout={proc.stdout!r}")
        print(f"stderr={proc.stderr!r}")
        return False

    if proc.stdout.strip() != "PONG":
        print("FAIL: bree ping did not use auto-discovered socket")
        print(f"stdout={proc.stdout!r}")
        print(f"stderr={proc.stderr!r}")
        return False

    return True


def main() -> int:
    try:
        cli_path = resolve_bree_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    if not test_base_debug_cli_discovers_bree_tag(cli_path):
        return 1

    if not test_variant_last_socket_markers(cli_path):
        return 1

    if not test_python_client_ignores_unknown_bundle_env():
        return 1

    if not test_python_client_treats_stable_override_as_implicit():
        return 1

    print("PASS: bree ping auto-discovers tagged socket from BREE_TAG")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
