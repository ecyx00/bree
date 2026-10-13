import BreeFoundation
import AppKit
import BREEProjectModel
import SwiftUI

/// Top-level SwiftUI view for a ``ProjectPanel``.
///
/// Renders the project chrome (project name, scheme/configuration pickers,
/// tab strip) and dispatches into the per-tab subviews.
struct ProjectPanelView: View {
    @Environment(\.breePalette) private var palette
    @ObservedObject var panel: ProjectPanel
    let isFocused: Bool
    let onRequestPanelFocus: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            chrome
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.surfaceBase)
        .onAppear {
            if case .idle = panel.loadState {
                panel.reload()
            }
        }
    }

    @ViewBuilder
    private var chrome: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Label(panel.displayTitle, systemImage: "hammer.fill")
                    .breeFont(.title)
                    .help(panel.projectURL.path)
                schemePicker
                configurationPicker
                Spacer(minLength: 0)
                Button {
                    panel.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.breeCompactIcon)
                .safeHelp(String(localized: "projectPanel.reload", defaultValue: "Reload Project"))
                .accessibilityLabel(String(localized: "projectPanel.reload", defaultValue: "Reload Project"))
            }
            if let error = panel.lastLoadError, case .loaded = panel.loadState {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .breeFont(.caption)
                    Text(String(
                        format: String(localized: "projectPanel.reloadErrors", defaultValue: "Reload returned errors: %@"),
                        error
                    ))
                        .breeFont(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Button {
                        panel.lastLoadError = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.breeCompactIcon)
                    .safeHelp(String(localized: "projectPanel.dismissReloadErrors", defaultValue: "Dismiss Errors"))
                    .accessibilityLabel(String(localized: "projectPanel.dismissReloadErrors", defaultValue: "Dismiss Errors"))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(palette.signalError.opacity(0.15))
                .foregroundStyle(palette.signalError)
                .clipShape(RoundedRectangle(cornerRadius: BreeMetrics.radiusSmall))
            }
            tabStrip
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var allSchemes: [SchemeSummary] {
        guard let model = panel.loadState.model else { return [] }
        var seen: Set<String> = []
        var out: [SchemeSummary] = []
        for module in model.modules {
            for scheme in module.schemes where seen.insert(scheme.name).inserted {
                out.append(scheme)
            }
        }
        return out
    }

    private var allConfigurationNames: [String] {
        guard let model = panel.loadState.model else { return [] }
        var seen: Set<String> = []
        var out: [String] = []
        for module in model.modules {
            for name in module.configurationNames where seen.insert(name).inserted {
                out.append(name)
            }
        }
        return out
    }

    @ViewBuilder
    private var schemePicker: some View {
        let schemes = allSchemes
        if !schemes.isEmpty {
            Picker(
                String(localized: "projectPanel.scheme", defaultValue: "Scheme"),
                selection: Binding(
                    get: { panel.selectedSchemeName ?? schemes.first?.name ?? "" },
                    set: { panel.selectedSchemeName = $0 }
                )
            ) {
                ForEach(schemes) { scheme in
                    Text(scheme.name).tag(scheme.name)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 200)
        }
    }

    @ViewBuilder
    private var configurationPicker: some View {
        let names = allConfigurationNames
        if !names.isEmpty {
            Picker(
                String(localized: "projectPanel.configuration", defaultValue: "Configuration"),
                selection: Binding(
                    get: { panel.selectedConfigurationName ?? names.first ?? "" },
                    set: { panel.selectedConfigurationName = $0 }
                )
            ) {
                ForEach(names, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .pickerStyle(.menu)
            .frame(minWidth: 180, maxWidth: 240)
        }
    }

    @ViewBuilder
    private var pathHint: some View {
        EmptyView()
    }

    @ViewBuilder
    private var tabStrip: some View {
        HStack(spacing: 2) {
            ForEach(ProjectPanelTab.allCases, id: \.self) { tab in
                Button(action: { panel.activeTab = tab }) {
                    Text(tab.displayLabel)
                        .breeFont(.tab, weight: .medium)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: BreeMetrics.radiusSmall)
                                .fill(panel.activeTab == tab
                                      ? palette.selectedFill
                                      : palette.hoverFill)
                        )
                        .foregroundStyle(palette.textPrimary)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch panel.loadState {
        case .idle, .loading:
            ProjectPanelStatusView(
                message: String(
                    format: String(localized: "projectPanel.loadingFormat", defaultValue: "Loading %@"),
                    panel.displayTitle
                )
            )
        case let .failed(reason):
            ProjectPanelStatusView(
                message: String(
                    format: String(localized: "projectPanel.failedFormat", defaultValue: "Failed: %@"),
                    reason
                )
            )
        case let .loaded(model):
            tabContent(for: model)
        }
    }

    @ViewBuilder
    private func tabContent(for model: ProjectModel) -> some View {
        switch panel.activeTab {
        case .files:
            ProjectFilesTabView(panel: panel, model: model)
        case .targets:
            ProjectTargetsTabView(panel: panel, model: model)
        case .buildSettings:
            ProjectBuildSettingsTabView(panel: panel, model: model)
        case .schemes:
            ProjectSchemesTabView(panel: panel, model: model)
        }
    }
}

struct ProjectPanelStatusView: View {
    let message: String
    @Environment(\.breePalette) private var palette

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Text(message)
                    .breeFont(.body)
                    .foregroundStyle(palette.textSecondary)
                Spacer()
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Reusable empty-state placeholder for the detail panes of each tab.
///
/// Replaces the floating 12 pt secondary text that read as a loading bug.
/// Centered icon (tertiary), 13 pt semibold title, 11 pt secondary hint.
struct ProjectEmptyDetailView: View {
    let systemImage: String
    let title: String
    let hint: String
    @Environment(\.breePalette) private var palette

    var body: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: systemImage)
                .breeFont(.title)
                .imageScale(.large)
                .foregroundStyle(palette.glyphTertiary)
            Text(title)
                .breeFont(.title)
                .foregroundStyle(palette.textPrimary)
            Text(hint)
                .breeFont(.caption)
                .foregroundStyle(palette.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
        .multilineTextAlignment(.center)
    }
}
