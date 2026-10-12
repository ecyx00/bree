#if DEBUG
import Foundation

/// Unified ring-buffer event log for key, mouse, focus, and split events.
/// Writes every entry to a debug log path so `tail -f` works in real time.
public final class DebugEventLog: @unchecked Sendable {
    public static let shared = DebugEventLog()

    private var entries: [String] = []
    private let capacity = 500
    private let queue = DispatchQueue(label: "cmux.debug-event-log")
    private static let logPath = resolveLogPath()

    /// When set, lines are handed to this closure instead of appended here.
    /// A host app whose own debug log writes to the same file installs a
    /// sink at startup so the file has exactly one serialized append path;
    /// two independent appenders interleave and reorder lines under load.
    /// Confined to `queue`.
    private var externalSink: (@Sendable (String) -> Void)?

    /// Fallback appender for standalone use (no sink installed): one handle
    /// opened with O_APPEND and kept open, so a concurrent appender cannot
    /// clobber whole lines. Confined to `queue`.
    private var appendHandle: FileHandle?

    /// Routes every subsequent line to `sink` (or back to the built-in file
    /// append when `nil`). The sink receives the raw message, without the
    /// timestamp prefix, so the receiving log applies its own line format.
    public static func setExternalSink(_ sink: (@Sendable (String) -> Void)?) {
        let log = shared
        log.queue.async {
            log.externalSink = sink
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static func sanitizePathToken(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let unicode = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let sanitized = String(unicode).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return sanitized.isEmpty ? "debug" : sanitized
    }

    private static func resolveLogPath() -> String {
        let env = ProcessInfo.processInfo.environment

        if let explicit = env["CMUX_DEBUG_LOG"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return explicit
        }

        if let tag = env["CMUX_TAG"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !tag.isEmpty {
            return "/tmp/cmux-debug-\(sanitizePathToken(tag)).log"
        }

        if let socketPath = env["CMUX_SOCKET_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !socketPath.isEmpty {
            let socketBase = URL(fileURLWithPath: socketPath).deletingPathExtension().lastPathComponent
            if socketBase.hasPrefix("cmux-debug-") {
                return "/tmp/\(socketBase).log"
            }
        }

        if let bundleId = Bundle.main.bundleIdentifier,
           bundleId != "com.cmuxterm.app.debug" {
            return "/tmp/cmux-debug-\(sanitizePathToken(bundleId)).log"
        }

        return "/tmp/cmux-debug.log"
    }

    public func log(_ msg: String) {
        let ts = Self.formatter.string(from: Date())
        queue.async {
            if let sink = self.externalSink {
                sink(msg)
                return
            }
            let entry = "\(ts) \(msg)"
            if self.entries.count >= self.capacity {
                self.entries.removeFirst()
            }
            self.entries.append(entry)
            // Append to file for real-time tail -f
            guard let data = (entry + "\n").data(using: .utf8) else { return }
            if self.appendHandle == nil {
                let fd = open(Self.logPath, O_WRONLY | O_APPEND | O_CREAT, 0o644)
                if fd >= 0 {
                    self.appendHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                }
            }
            guard let handle = self.appendHandle else { return }
            do {
                try handle.write(contentsOf: data)
            } catch {
                // The file may have been rotated away; reopen on the next line.
                self.appendHandle = nil
            }
        }
    }

    /// Write all buffered entries to the log file (full dump, replacing contents).
    public func dump() {
        queue.async {
            // With a sink installed the receiving log owns the file; replacing
            // its contents here would throw away the other writer's lines.
            if self.externalSink != nil { return }
            // The atomic write replaces the inode; reopen the handle lazily.
            try? self.appendHandle?.close()
            self.appendHandle = nil
            let content = self.entries.joined(separator: "\n") + "\n"
            try? content.write(toFile: Self.logPath, atomically: true, encoding: .utf8)
        }
    }
}

/// Convenience free function. Logs the message and appends to the configured debug log path.
public func dlog(_ msg: String) {
    DebugEventLog.shared.log(msg)
}
#endif
