import AppKit
import CmuxFoundation
import SwiftUI

/// **Wiki** settings: the global wiki folder (a project without its own `.bree/wiki` reads wikis from here).
/// The folder is stored in UserDefaults under ``WikiFolderSetting/defaultsKey``; the default is `<Bree home>/wiki`.
@MainActor
public struct WikiSection: View {
    @State private var folder = WikiFolderSetting.resolved()

    public init() {}

    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.wiki", defaultValue: "Wiki"), section: .wiki)
            SettingsCard {
                SettingsCardRow(
                    searchAnchorID: "setting:wiki:folder",
                    String(localized: "settings.wiki.folder.title", defaultValue: "Wiki Folder"),
                    subtitle: (folder as NSString).abbreviatingWithTildeInPath
                ) {
                    HStack(spacing: 8) {
                        Button(String(localized: "settings.wiki.folder.choose", defaultValue: "Choose…")) { choose() }
                            .accessibilityIdentifier("SettingsWikiFolderChoose")
                        Button(String(localized: "settings.wiki.folder.reset", defaultValue: "Default")) {
                            UserDefaults.standard.removeObject(forKey: WikiFolderSetting.defaultsKey)
                            folder = WikiFolderSetting.resolved()
                        }
                        .disabled(UserDefaults.standard.string(forKey: WikiFolderSetting.defaultsKey) == nil)
                    }
                    .controlSize(.small)
                }
            }
            .settingsSearchAnchors(["setting:wiki:folder"])
            SettingsCardNote(
                String(localized: "settings.wiki.folder.subtitle", defaultValue: "Used when a project has no .bree/wiki folder of its own. Commands declared here run without asking.")
            )
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: folder, isDirectory: true)
        panel.prompt = String(localized: "settings.wiki.folder.prompt", defaultValue: "Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: WikiFolderSetting.defaultsKey)
        folder = WikiFolderSetting.resolved()
    }
}
