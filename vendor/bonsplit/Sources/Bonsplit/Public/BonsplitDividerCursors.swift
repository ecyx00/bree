import AppKit

/// Host-injectable cursors for split divider cursor rects.
///
/// When set, managed split views register these over their divider effective
/// rects instead of AppKit's built-in system resize cursors, so a host that
/// draws its own resize-cursor family (e.g. to match a custom four-way corner
/// cursor) keeps one visual set. Unset (the default) preserves AppKit's
/// native divider cursors.
@MainActor
public enum BonsplitDividerCursors {
    public static var vertical: NSCursor?
    public static var horizontal: NSCursor?
}
