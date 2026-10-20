import Foundation

extension SurfaceResourceID {
    /// The numeric port encoded by the canonical remote forwarded-port identity.
    /// Snapshot browser views that visit localhost are normalized to this key so
    /// the machine port and its workspace row share one resource identity.
    public var forwardedPort: Int? {
        guard kind == .browser, key.hasPrefix("port:") else { return nil }
        let value = key.dropFirst("port:".count)
        guard let port = Int(value), (1...65_535).contains(port) else { return nil }
        guard key == SurfaceResourceID.portKey(port) else { return nil }
        return port
    }

    /// Whether this id is the machine-level forwarded-port resource.
    public var isForwardedPort: Bool { forwardedPort != nil }
}

extension SurfaceResourceID {
    /// The key every provider uses for a machine's one VNC display (T10 makes this a list).
    public static let desktopDisplayKey = "display:1"

    /// The key for the browser that shows a forwarded HTTP port.
    public static func portKey(_ port: Int) -> String { "port:\(port)" }
}
