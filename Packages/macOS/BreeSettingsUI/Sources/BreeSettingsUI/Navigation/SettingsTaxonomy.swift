import Foundation

/// Presentation-only grouping for the Settings sidebar.
///
/// The browse sidebar lists only the host panes. Sections that render inside
/// a host (see ``SettingsSectionMountModel/hostSection(for:)``) stay
/// addressable by search, deep links, and anchors but get no sidebar row.
enum SettingsTaxonomyGroup: String, CaseIterable, Identifiable, Sendable {
    case main

    /// Stable identity for SwiftUI section iteration.
    var id: Self { self }

    /// Localized heading shown above this group in the default browse sidebar.
    var title: String {
        String(localized: "settings.taxonomy.general", defaultValue: "General", bundle: .module)
    }

    /// Existing navigation leaves shown under this presentation category.
    var sections: [SettingsSectionID] {
        [.app, .notifications, .editorViewers, .themes, .terminal, .automation, .sidebarAppearance, .browser, .keyboardShortcuts, .wiki, .advanced]
    }

    /// All existing navigation leaves in the order used by grouped browsing.
    static var sectionsInDisplayOrder: [SettingsSectionID] {
        allCases.flatMap(\.sections)
    }
}
