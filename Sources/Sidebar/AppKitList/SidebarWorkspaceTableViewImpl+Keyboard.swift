import AppKit

/// Receiver of the left sidebar's keyboard intents. The main-window focus
/// controller implements it, so the table never touches selection or terminal
/// focus itself. No intent here is destructive: nothing closes or deletes.
@MainActor
protocol SidebarWorkspaceKeyboardDelegate: AnyObject {
    /// Select the workspace and move focus to its terminal.
    func sidebarKeyboardActivate(workspaceId: UUID)
    /// Collapse or expand a workspace group.
    func sidebarKeyboardToggleGroup(groupId: UUID)
    /// Return focus to the terminal without changing the workspace.
    func sidebarKeyboardCancel()
    /// Another responder took focus; the ring is already gone.
    func sidebarKeyboardDidEnd()
}

extension SidebarWorkspaceTableViewImpl {
    var isKeyboardNavigationActive: Bool { keyboardRingRowId != nil }

    /// Start keyboard navigation with the ring on the selected workspace's row
    /// (or the first row). Returns false when the list has no rows.
    @discardableResult
    func beginKeyboardNavigation(selectedWorkspaceId: UUID?) -> Bool {
        guard let rows = workspaceController?.rows, !rows.isEmpty else { return false }
        let start = rows.first { $0.workspaceId == selectedWorkspaceId && !$0.isGroupHeader }
            ?? rows.first { $0.workspaceId == selectedWorkspaceId }
            ?? rows[0]
        keyboardRingRowId = start.id
        keyboardRingFallbackGroupId = start.groupId
        guard window?.makeFirstResponder(self) == true else {
            keyboardRingRowId = nil
            return false
        }
        updateKeyboardRing(announce: true)
        return true
    }

    func endKeyboardNavigation() {
        keyboardRingRowId = nil
        keyboardRingFallbackGroupId = nil
        keyboardRingView.removeFromSuperview()
    }

    /// Index of the ring's row in `rows`. A row that vanished (group collapsed,
    /// workspace reordered away) falls back to its group header and re-keys the ring.
    private func resolvedKeyboardRingIndex(in rows: [SidebarWorkspaceTableRowConfiguration]) -> Int? {
        guard let ringId = keyboardRingRowId else { return nil }
        if let index = rows.firstIndex(where: { $0.id == ringId }) { return index }
        guard let groupId = keyboardRingFallbackGroupId,
              let header = rows.firstIndex(where: { $0.isGroupHeader && $0.groupId == groupId }) else { return nil }
        keyboardRingRowId = rows[header].id
        return header
    }

    /// Re-resolve the ring's row after rows reorder, collapse or recycle; ends
    /// navigation when the row is gone for good.
    func updateKeyboardRing(announce: Bool) {
        guard let rows = workspaceController?.rows, keyboardRingRowId != nil else { return }
        let index = resolvedKeyboardRingIndex(in: rows)
        guard let row = index, row < numberOfRows else {
            endKeyboardNavigation()
            return
        }
        let rect = rect(ofRow: row).insetBy(dx: 3, dy: 1)
        if announce { scrollRowToVisible(row) }
        keyboardRingView.frame = rect
        keyboardRingView.needsDisplay = true
        // Rows inserted later land above older subviews, so re-raise on every update.
        // Only when needed: re-adding on every pass would re-trigger layout.
        if subviews.last !== keyboardRingView {
            addSubview(keyboardRingView, positioned: .above, relativeTo: nil)
        }
        let label = keyboardRowLabel(rows: rows, index: row)
        keyboardRingView.setAccessibilityLabel(label)
        if announce {
            NSAccessibility.post(element: keyboardRingView, notification: .focusedUIElementChanged)
            NSAccessibility.post(
                element: self,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: label,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ]
            )
        }
    }

    private func keyboardRowLabel(rows: [SidebarWorkspaceTableRowConfiguration], index: Int) -> String {
        let row = rows[index]
        if row.isGroupHeader, let model = row.appKitGroupHeaderModel {
            let format = model.isCollapsed
                ? String(localized: "sidebar.keyboard.row.group.collapsed", defaultValue: "%@, group, collapsed")
                : String(localized: "sidebar.keyboard.row.group.expanded", defaultValue: "%@, group, expanded")
            return String.localizedStringWithFormat(format, model.name)
        }
        let title = row.appKitWorkspaceRowWorkspace?.title
            ?? String(localized: "workspace.displayName.fallback", defaultValue: "Workspace")
        return String.localizedStringWithFormat(
            String(localized: "sidebar.keyboard.row.workspace", defaultValue: "%@, workspace, %d of %d"),
            title, index + 1, rows.count
        )
    }

    private func moveKeyboardRing(by delta: Int) {
        guard let rows = workspaceController?.rows,
              let current = resolvedKeyboardRingIndex(in: rows) else { return }
        let next = min(max(current + delta, 0), rows.count - 1)
        guard next != current else { return }
        keyboardRingRowId = rows[next].id
        keyboardRingFallbackGroupId = rows[next].groupId
        updateKeyboardRing(announce: true)
    }

    /// Handles one key while navigation is active. Returns true when consumed.
    /// Everything except Tab is consumed so stray keys never reach type-select,
    /// and Delete/Backspace are deliberately inert.
    func handleKeyboardNavigation(_ event: NSEvent) -> Bool {
        guard let rows = workspaceController?.rows,
              let current = resolvedKeyboardRingIndex(in: rows) else {
            // The ring's row is gone for good; do not leave a dead ring swallowing keys.
            endKeyboardNavigation()
            return false
        }
        let row = rows[current]
        switch event.keyCode {
        case 48:
            return false
        case 126:
            moveKeyboardRing(by: -1)
        case 125:
            moveKeyboardRing(by: 1)
        case 36, 76:
            endKeyboardNavigation()
            keyboardDelegate?.sidebarKeyboardActivate(workspaceId: row.workspaceId)
        case 49:
            if let groupId = row.groupId {
                keyboardRingFallbackGroupId = groupId
                // Park the ring on the header first: collapsing removes member rows.
                if let header = rows.first(where: { $0.isGroupHeader && $0.groupId == groupId }) {
                    keyboardRingRowId = header.id
                }
                keyboardDelegate?.sidebarKeyboardToggleGroup(groupId: groupId)
            }
        case 53:
            endKeyboardNavigation()
            keyboardDelegate?.sidebarKeyboardCancel()
        default:
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.intersection([.command, .control, .option]).isEmpty {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "j": moveKeyboardRing(by: 1)
                case "k": moveKeyboardRing(by: -1)
                default: break
                }
            }
        }
        return true
    }
}
