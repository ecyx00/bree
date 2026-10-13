import Combine
import SwiftUI

/// The Pulse line of one sidebar row. It formats the time in the current state
/// at render time (a minute timeline) and swaps in the away-change count while
/// a "changed since you looked" list exists. Only this leaf observes
/// `AttentionStore`, and only the count of its own workspace, so other rows
/// do not re-render when one workspace's files change.
struct SidebarPulseRow: View {
    let pulse: SidebarWorkspacePulse.Input
    let workspaceId: UUID
    let font: Font
    let color: Color

    @Environment(\.breePalette) private var palette
    @State private var awayChangedCount = 0
    @State private var resource: ResourceGuardWorkspaceState?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let line = pulse.line(
                now: context.date,
                changedFileCountOverride: awayChangedCount > 0 ? awayChangedCount : nil
            )
            let suffix = SidebarWorkspacePulse.resourceText(resource)
            if line != nil || suffix != nil {
                // The suffix stays whole; only the base line truncates.
                HStack(spacing: 0) {
                    if let line {
                        Text(line)
                            .font(font)
                            .foregroundColor(color)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let suffix {
                        let high = resource?.isHigh == true
                        let separator = Text(line == nil ? "" : SidebarWorkspacePulse.separator).foregroundColor(color)
                        let value = resourceLabel(suffix, high: high)
                            .foregroundColor(high ? palette.signalError : palette.textSecondary)
                        (separator + value)
                            .font(font)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("SidebarPulseRow")
            }
        }
        .onReceive(
            ResourceGuard.shared.$states
                .map { $0[workspaceId] }
                .removeDuplicates()
        ) { resource = $0 }
        .onReceive(
            AttentionStore.shared.$changeLogs
                .map { $0[workspaceId]?.count ?? 0 }
                .removeDuplicates()
        ) { awayChangedCount = $0 }
    }
}

/// A critical resource reads as red text with a warning glyph, so the state is not colour only.
private func resourceLabel(_ text: String, high: Bool) -> Text {
    high ? Text(Image(systemName: "exclamationmark.triangle.fill")) + Text(" " + text) : Text(text)
}

/// Resource alarm for a row that has no pulse line (minimal sidebar). Renders
/// nothing unless this workspace is high or paused, so no empty line appears.
/// Observes only its own workspace's entry, like `SidebarPulseRow`.
struct SidebarResourceRow: View {
    let workspaceId: UUID
    let font: Font

    @Environment(\.breePalette) private var palette
    @State private var resource: ResourceGuardWorkspaceState?

    var body: some View {
        Group {
            if let suffix = SidebarWorkspacePulse.resourceText(resource) {
                resourceLabel(suffix, high: resource?.isHigh == true)
                    .font(font)
                    .foregroundColor(resource?.isHigh == true ? palette.signalError : palette.textSecondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("SidebarResourceRow")
            }
        }
        .onReceive(
            ResourceGuard.shared.$states
                .map { $0[workspaceId] }
                .removeDuplicates()
        ) { resource = $0 }
    }
}
