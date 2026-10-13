/// A single command captured from a `Button`'s action closure.
///
/// The interpreter records the call shape; a host runtime executes it. The
/// `bree` case maps onto bree's socket command dispatcher (`method` + string
/// arguments), giving interpreted buttons the breadth of the bree CLI.
public enum ActionCommand: Codable, Sendable, Equatable {
    /// A bree command: a dispatcher method plus named string params, e.g.
    /// `bree("workspace.select", workspace_id: w.id)` →
    /// `.bree("workspace.select", ["workspace_id": "<uuid>"])`. Maps directly
    /// onto the socket command protocol (`{"method","params"}`).
    case bree(method: String, params: [String: String])
    case log(String)
    /// Opens a URL (host runs it, e.g. via the workspace opener).
    case openURL(String)
}
