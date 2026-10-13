import XCTest

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

final class BreeConfigNamedColorTests: XCTestCase {
    private func decode(_ json: String, colorDefaults: UserDefaults? = nil) throws -> BreeConfigFile {
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        if let colorDefaults {
            decoder.userInfo[.breeWorkspaceColorDefaults] = colorDefaults
        }
        return try decoder.decode(BreeConfigFile.self, from: data)
    }

    func testDecodeWorkspaceCommandAcceptsNamedColor() throws {
        let suiteName = "bree-config-named-color-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        WorkspaceTabColorSettings.persistPaletteMap(["Indigo": "#283593"], defaults: defaults)

        let json = """
        {
          "commands": [{
            "name": "Dev env",
            "workspace": {
              "name": "Development",
              "color": "Indigo"
            }
          }]
        }
        """
        let config = try decode(json, colorDefaults: defaults)
        XCTAssertEqual(config.commands[0].workspace?.color, "#283593")
    }

    func testDecodeWorkspaceCommandRejectsUnknownNamedColor() {
        let suiteName = "bree-config-unknown-color-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let json = """
        {
          "commands": [{
            "name": "Dev env",
            "workspace": {
              "name": "Development",
              "color": "Definitely Not A Palette Color"
            }
          }]
        }
        """
        XCTAssertThrowsError(try decode(json, colorDefaults: defaults))
    }

    @MainActor
    func testConfigParseCacheInvalidatesWhenWorkspaceColorPaletteChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "bree-config-store-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let previousPalette = UserDefaults.standard.dictionary(forKey: WorkspaceTabColorSettings.paletteKey)
        defer {
            if let previousPalette {
                UserDefaults.standard.set(previousPalette, forKey: WorkspaceTabColorSettings.paletteKey)
            } else {
                UserDefaults.standard.removeObject(forKey: WorkspaceTabColorSettings.paletteKey)
            }
        }

        let configURL = root.appendingPathComponent("bree.json")
        let json = """
        {
          "commands": [{
            "name": "Dev env",
            "workspace": {
              "name": "Development",
              "color": "Codex Test"
            }
          }]
        }
        """
        try json.write(to: configURL, atomically: true, encoding: .utf8)

        let store = BreeConfigStore(globalConfigPath: configURL.path, startFileWatchers: false)
        WorkspaceTabColorSettings.persistPaletteMap(["Codex Test": "#111111"])
        store.loadAll()
        XCTAssertEqual(store.loadedCommands.first?.workspace?.color, "#111111")

        WorkspaceTabColorSettings.persistPaletteMap(["Codex Test": "#222222"])
        store.loadAll()
        XCTAssertEqual(store.loadedCommands.first?.workspace?.color, "#222222")
    }
}
