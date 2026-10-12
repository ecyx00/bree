import AppKit
import CmuxFoundation
import CmuxSidebar

/// Leaf AppKit views for the pure-AppKit workspace row: unread badge,
/// progress bar. Each is configured with values
/// only and draws without Auto Layout.

extension NSTextField {
    /// Unconstrained text measurement for manual layout. Never use
    /// `intrinsicContentSize` to size these labels: on a truncating
    /// single-line field it caps at the CURRENT frame width, so a pooled
    /// view laid out narrow once (they start at zero width) reports — and
    /// keeps — the truncated width no matter how much space the row has.
    /// That is exactly the "PR #4  o…" bug.
    var sidebarNaturalCellSize: NSSize {
        cell?.cellSize(forBounds: NSRect(
            x: 0, y: 0,
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )) ?? .zero
    }
}

/// Circle unread-count badge (parity with SidebarWorkspaceUnreadBadge).
/// Draws the count directly so the glyph is optically centered — NSTextField
/// intrinsic sizing carries asymmetric insets that shift small digits.
@MainActor
final class SidebarRowUnreadBadgeView: NSView {
    private var text: NSString = ""
    private var textAttributes: [NSAttributedString.Key: Any] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(count: Int, fillColor: NSColor, textColor: NSColor, font: NSFont) {
        text = NSString(string: "\(count)")
        textAttributes = [.font: font, .foregroundColor: textColor]
        layer?.backgroundColor = fillColor.cgColor
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard text.length > 0, let font = textAttributes[.font] as? NSFont else { return }
        let size = text.size(withAttributes: textAttributes)
        // Center on the digit's cap-height band, not the full line box, so
        // single digits sit optically centered in the circle.
        let capCenterOffset = (font.ascender + font.descender) / 2
        let y = bounds.midY - size.height / 2 + (size.height / 2 - font.ascender + capCenterOffset)
        text.draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: y),
            withAttributes: textAttributes
        )
    }
}

/// Capsule progress bar (track + leading-anchored fill + optional label).
@MainActor
final class SidebarRowProgressView: NSView {
    private let trackView = NSView()
    private let fillView = NSView()
    let label = NSTextField(labelWithString: "")
    private var fraction: CGFloat = 0
    private var barHeight: CGFloat = 3

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        trackView.wantsLayer = true
        fillView.wantsLayer = true
        addSubview(trackView)
        addSubview(fillView)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        fraction: CGFloat,
        barHeight: CGFloat,
        trackColor: NSColor,
        fillColor: NSColor,
        labelText: String?,
        labelFont: NSFont,
        labelColor: NSColor
    ) {
        self.fraction = max(0, min(1, fraction))
        self.barHeight = barHeight
        trackView.layer?.backgroundColor = trackColor.cgColor
        fillView.layer?.backgroundColor = fillColor.cgColor
        label.isHidden = labelText == nil
        label.stringValue = labelText ?? ""
        label.font = labelFont
        label.textColor = labelColor
        needsLayout = true
    }

    static func height(barHeight: CGFloat, labelText: String?, labelFont: NSFont) -> CGFloat {
        guard labelText != nil else { return barHeight }
        return barHeight + 2 + ceil(labelFont.ascender - labelFont.descender + labelFont.leading)
    }

    override func layout() {
        super.layout()
        trackView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: barHeight)
        trackView.layer?.cornerRadius = barHeight / 2
        fillView.frame = NSRect(x: 0, y: 0, width: bounds.width * fraction, height: barHeight)
        fillView.layer?.cornerRadius = barHeight / 2
        if !label.isHidden {
            let size = label.sidebarNaturalCellSize
            label.frame = NSRect(x: 0, y: barHeight + 2, width: min(ceil(size.width), bounds.width), height: size.height)
        }
    }
}

extension NSAttributedString.Key {
    /// Row-owned replacement for `.link`. AppKit gives no way to override the
    /// color it paints `.link` runs in, so the sidebar carries the destination
    /// here and styles the run itself.
    static let sidebarRowLink = NSAttributedString.Key("com.cmux.sidebarRowLink")
}

extension Notification.Name {
    /// Posted (object: workspace id) when shell activity or a panel title
    /// changes; the sidebar re-derives line 2 for the affected rows only.
    static let sidebarRowLineInvalidated = Notification.Name("com.cmux.sidebarRowLineInvalidated")
}

/// Second line of a workspace card: what the workspace is doing right now.
/// Always present (agent, running command, or idle branch and directory).
/// Value type so it joins the row model's equality (and therefore
/// re-measurement) without observing anything itself.
struct SidebarRowAgentLine: Equatable {
    /// First match wins in this order (see the chrome review, decision 3).
    enum Kind: Equatable {
        case needsApproval, needsInput, working, agentIdle, agentError, commandRunning, idle
    }

    let kind: Kind
    /// Human summary (in-progress todo, or the agent terminal's title); SF Pro.
    let human: String?
    /// Machine text (agent step, running command); SF Mono.
    let machine: String?
    let branch: String?
    /// Short working directory (`~/tmp/bree-rs`).
    let directory: String?
    /// When the state last changed; drives the age on line 1.
    let since: Date?
    /// Messages waiting in `AgentQueueStore` for this workspace's panes.
    var queued: Int = 0

    static let maxSummaryCharacters = 160

    static func make(card: AgentLensCard, terminalTitle: String?) -> SidebarRowAgentLine {
        let kind: Kind
        switch card.state {
        case .needsInput: kind = card.needsApproval ? .needsApproval : .needsInput
        case .error: kind = .agentError
        case .running: kind = .working
        case .idle: kind = .agentIdle
        }
        let human = clean(card.todos?.current)
        return SidebarRowAgentLine(
            kind: kind,
            human: human ?? (step(card.step) == nil ? cleanTerminalTitle(terminalTitle) : nil),
            machine: step(card.step),
            branch: nil,
            directory: nil,
            since: card.lastEventAt
        )
    }

    /// First card per workspace (the store sorts needs input, error, running, idle).
    @MainActor
    static func lines() -> [UUID: SidebarRowAgentLine] {
        var result: [UUID: SidebarRowAgentLine] = [:]
        for card in AgentLensStore.shared.cards where result[card.workspaceID] == nil {
            let title = card.surfaceID.flatMap {
                AppDelegate.shared?.workspaceFor(tabId: card.workspaceID)?.panelTitles[$0]
            }
            var line = make(card: card, terminalTitle: title)
            line.queued = queuedCount(workspaceId: card.workspaceID)
            result[card.workspaceID] = line
        }
        return result
    }

    @MainActor
    static func queuedCount(workspaceId: UUID) -> Int {
        let counts = AgentQueueStore.shared.counts
        guard !counts.isEmpty, let panels = AppDelegate.shared?.workspaceFor(tabId: workspaceId)?.panels else { return 0 }
        return panels.keys.reduce(0) { $0 + (counts[$1] ?? 0) }
    }

    @MainActor
    static func current(workspaceId: UUID) -> SidebarRowAgentLine {
        lines()[workspaceId] ?? shell(workspaceId: workspaceId)
    }

    /// Time a workspace's shell state last changed, keyed by workspace; the
    /// shell reports no timestamp of its own.
    @MainActor private static var shellChanges: [UUID: (key: String, at: Date)] = [:]

    /// Line for a workspace with no agent card: the running foreground command
    /// (shell integration `commandRunning`; the terminal title carries the
    /// command text) or, when idle, branch and short directory.
    /// Last exit status is not reported by shell integration, so there is no
    /// "exit N" row.
    @MainActor
    static func shell(workspaceId: UUID) -> SidebarRowAgentLine {
        let workspace = AppDelegate.shared?.workspaceFor(tabId: workspaceId)
        let panelId = workspace?.focusedPanelId
        let running = panelId.flatMap { workspace?.panelShellActivityStates[$0] } == .commandRunning
        let branch = panelId.flatMap { workspace?.panelGitBranches[$0]?.branch } ?? workspace?.gitBranch?.branch
        let directory = (panelId.flatMap { workspace?.panelDirectories[$0] } ?? workspace?.currentDirectory)
            .flatMap { $0.isEmpty ? nil : abbreviated($0) }
        let command = running ? cleanTerminalTitle(panelId.flatMap { workspace?.panelTitles[$0] }) : nil
        let key = running ? "running" : "idle"
        let previous = shellChanges[workspaceId]
        let at = previous?.key == key ? previous!.at : Date()
        if previous?.key != key { shellChanges[workspaceId] = (key, at) }
        return SidebarRowAgentLine(
            kind: running ? .commandRunning : .idle,
            human: nil,
            machine: command,
            branch: running ? nil : branch,
            directory: running ? nil : directory,
            since: at,
            queued: queuedCount(workspaceId: workspaceId)
        )
    }

    private static func abbreviated(_ path: String) -> String {
        let tilded = (path as NSString).abbreviatingWithTildeInPath
        let parts = tilded.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count > 3 else { return tilded }
        return (tilded.hasPrefix("~") ? "~/" : "/") + "\u{2026}/" + parts.suffix(2).joined(separator: "/")
    }

    private static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return flat.isEmpty ? nil : String(flat.prefix(maxSummaryCharacters))
    }

    private static func step(_ step: AgentLensCard.Step?) -> String? {
        guard let step else { return nil }
        var target = step.target?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if target.hasPrefix("/"), !target.contains(" ") { target = (target as NSString).lastPathComponent }
        return clean(target.isEmpty ? step.tool : "\(step.tool) \(target)")
    }

    /// Programs prefix their title with a spinner, dingbat, symbol or emoji
    /// (Claude Code: `✳ Task`); those leading characters are dropped.
    private static func cleanTerminalTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let scalars = title.unicodeScalars.drop { scalar in
            (0x2800...0x28FF).contains(scalar.value)
                || scalar.properties.isWhitespace
                || scalar.properties.isEmojiPresentation
                || scalar.properties.isEmoji && scalar.value > 0x7F
                || (0x2190...0x2BFF).contains(scalar.value)
                || ["\u{B7}", "*", "\u{25CF}", "\u{25CB}"].contains(String(scalar))
        }
        let text = clean(String(String.UnicodeScalarView(scalars)))
        return text == "Claude Code" ? nil : text
    }

    /// "now", "2m", "3h", "4d": one abbreviated unit, localized by the system formatter.
    static func ageText(since: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(since)
        if seconds < 60 { return String(localized: "sidebar.card.age.now", defaultValue: "now") }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = seconds < 3600 ? [.minute] : seconds < 86_400 ? [.hour] : [.day]
        return formatter.string(from: seconds) ?? ""
    }
}

/// The 8 pt leading slot of a card's first line. Always occupies its width so
/// names align; draws nothing when idle. Colour is never the only carrier:
/// line 2 always says the state in words.
final class SidebarRowStatusMarkerView: NSView {
    enum Marker: Equatable { case none, attention, success, error, activity }

    static let side: CGFloat = 8
    private var marker: Marker = .none

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Self.side / 2
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func configure(_ marker: Marker, color: NSColor) {
        self.marker = marker
        layer?.backgroundColor = marker == .none ? nil : color.cgColor
        isHidden = marker == .none
        let pulses = marker == .activity && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if pulses {
            guard layer?.animation(forKey: "pulse") == nil else { return }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.35
            pulse.duration = 0.9
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            layer?.add(pulse, forKey: "pulse")
        } else {
            layer?.removeAnimation(forKey: "pulse")
        }
    }
}
