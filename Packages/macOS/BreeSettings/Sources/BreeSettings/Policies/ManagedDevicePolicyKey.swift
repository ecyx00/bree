import Foundation

/// A device-management policy bree honors when an administrator forces it
/// through a macOS configuration profile (MDM "Custom Settings" payload).
///
/// The raw value is the preference key an administrator sets in the
/// ``ManagedDevicePolicy/releasePayloadDomain`` preference domain. Policy
/// keys are deliberately separate from the user-facing settings catalog:
/// a managed policy is tier-0 — it wins over environment variables, user
/// `UserDefaults`, `bree.json` imports, and built-in defaults — and it can
/// never be changed from inside the app.
public enum ManagedDevicePolicyKey: String, CaseIterable, Sendable {
    /// Disables every embedded-browser surface: browser panes and tabs,
    /// terminal-link interception, and browser creation from automation,
    /// layouts, and session restore.
    case disableEmbeddedBrowser = "DisableEmbeddedBrowser"

    /// Disables the Mac acting as a remote view/control host for the bree
    /// iOS companion app: the Iroh host runtime, the legacy TCP pairing
    /// listener, connection admission, and device pairing.
    case disableRemoteControl = "DisableRemoteControl"

    /// Disables discovery of other account Macs in the My Devices surfaces.
    /// Incoming access to this Mac is controlled independently by
    /// ``disableIncomingDeviceAccess``.
    case disableDeviceDiscovery = "DisableDeviceDiscovery"

    /// Disables this Mac accepting incoming account-device or iOS sessions.
    /// Outbound discovery and control remain available unless separately denied.
    case disableIncomingDeviceAccess = "DisableIncomingDeviceAccess"

    /// Disables bree-created remote connections: SSH, Mosh, remote tmux, and
    /// the remote registry, from every entry point (CLI, palette, menus,
    /// session restore, automation). Terminals on this Mac are unaffected,
    /// and a user's own `ssh` typed into a shell is out of scope by design.
    case disableRemoteConnections = "DisableRemoteConnections"

    /// Disables bree-mediated file transfer: drag-and-drop and pasted-image
    /// uploads into remote terminals, the configured custom upload command,
    /// Local drops into local terminals still work,
    /// and a user's own `scp` in a shell is out of scope by design.
    case disableFileTransfer = "DisableFileTransfer"

    /// Disables bree-managed Iroh networking: the host runtime, its relay
    /// traffic, and the client-side connectivity subscriber. Local terminal
    /// work is unaffected. ``disableRemoteControl`` disables the Mac as an
    /// iOS remote-control host specifically; this key disables the Iroh
    /// transport itself, including the paths that are not remote control.
    case disableIrohNetworking = "DisableIrohNetworking"

    /// Disables the `webhook` action of automation rules, which posts event
    /// payloads with caller-supplied headers to any http(s) URL.
    case disableAutomationWebhooks = "DisableAutomationWebhooks"

    /// Disables the embedded browser's click-through on certificate errors:
    /// the error page offers no bypass, and no earlier grant is honored.
    case disableTLSTrustBypass = "DisableTLSTrustBypass"

    /// Disables interpreted custom sidebars from `~/.config/bree/sidebars`
    /// (user- or agent-authored code that can dispatch `bree(...)` commands).
    case disableCustomSidebars = "DisableCustomSidebars"

    /// Disables uploading local AI credentials (Claude/Codex OAuth tokens,
    /// Anthropic/OpenAI API keys) to the bree tenant: `aiAccounts.upload` and
    /// the coderouter upstream-account writes.
    case disableAICredentialUpload = "DisableAICredentialUpload"

    /// Forces the local automation socket to a restrictive access mode. The
    /// only valid profile values are the strings `breeOnly` and `off`;
    /// malformed or broader values fail closed to `off`.
    case socketControlMode = "SocketControlMode"

    /// Restricts embedded-browser top-level navigations to the administrator's
    /// URL patterns. An empty forced array denies every external web origin
    /// while preserving bree-owned internal documents. Loopback origins and
    /// local `file:` documents stay available by default under a forced list;
    /// ``browserAllowLocalhost`` and ``browserAllowLocalFiles`` turn those
    /// defaults off.
    case browserURLAllowlist = "BrowserURLAllowlist"

    /// Whether the embedded browser may open loopback origins (`localhost`,
    /// `*.localhost`, `127.0.0.1`, `::1`, `0.0.0.0`, on any port) without a
    /// ``browserURLAllowlist`` entry. An allow-style key: it defaults to
    /// `true`, and a profile forces `false` to block local development
    /// servers, even ones a list names explicitly.
    case browserAllowLocalhost = "BrowserAllowLocalhost"

    /// Whether the embedded browser may show local `file:` documents (files
    /// opened through bree, dropped onto a browser pane, or linked from
    /// another local document). An allow-style key: it defaults to `true`,
    /// and a profile forces `false` to block local files whether or not a
    /// ``browserURLAllowlist`` is forced.
    case browserAllowLocalFiles = "BrowserAllowLocalFiles"

    /// The keys whose enforced state is "forced to `false`" rather than
    /// "forced to `true`". Every other Boolean key is a `Disable…` switch.
    public static let allowStyleKeys: Set<ManagedDevicePolicyKey> = [
        .browserAllowLocalhost,
        .browserAllowLocalFiles,
    ]
}
