import Foundation
import Testing
@testable import BreeCore

@Suite("WorkspaceRemoteDaemonManifest decoding")
struct WorkspaceRemoteDaemonManifestTests {
    private let manifestJSON = """
    {
      "schemaVersion": 1,
      "appVersion": "0.20.0",
      "releaseTag": "breed-remote-v0.20.0",
      "releaseURL": "https://github.com/ecyx00/bree/releases/tag/breed-remote-v0.20.0",
      "checksumsAssetName": "checksums.txt",
      "checksumsURL": "https://example.invalid/checksums.txt",
      "entries": [
        {
          "goOS": "linux",
          "goArch": "amd64",
          "assetName": "breed-remote-linux-amd64",
          "downloadURL": "https://example.invalid/breed-remote-linux-amd64",
          "sha256": "abc123"
        },
        {
          "goOS": "darwin",
          "goArch": "arm64",
          "assetName": "breed-remote-darwin-arm64",
          "downloadURL": "https://example.invalid/breed-remote-darwin-arm64",
          "sha256": "def456"
        }
      ]
    }
    """

    @Test("decodes the embedded manifest JSON shape")
    func decodesManifest() throws {
        let manifest = try JSONDecoder().decode(
            WorkspaceRemoteDaemonManifest.self,
            from: Data(manifestJSON.utf8)
        )
        #expect(manifest.schemaVersion == 1)
        #expect(manifest.appVersion == "0.20.0")
        #expect(manifest.entries.count == 2)
    }

    @Test("entry lookup matches on the exact GOOS/GOARCH pair")
    func entryLookup() throws {
        let manifest = try JSONDecoder().decode(
            WorkspaceRemoteDaemonManifest.self,
            from: Data(manifestJSON.utf8)
        )
        #expect(manifest.entry(goOS: "linux", goArch: "amd64")?.sha256 == "abc123")
        #expect(manifest.entry(goOS: "darwin", goArch: "arm64")?.assetName == "breed-remote-darwin-arm64")
        #expect(manifest.entry(goOS: "linux", goArch: "arm64") == nil)
    }

    @Test("decodes from an Info dictionary under the wire-pinned key")
    func decodesFromInfoDictionary() throws {
        let manifest = try #require(WorkspaceRemoteDaemonManifest(infoDictionary: [
            WorkspaceRemoteDaemonManifest.infoDictionaryKey: manifestJSON,
        ]))
        #expect(WorkspaceRemoteDaemonManifest.infoDictionaryKey == "BREERemoteDaemonManifestJSON")
        #expect(manifest.releaseTag == "breed-remote-v0.20.0")
        #expect(manifest.entry(goOS: "linux", goArch: "amd64")?.assetName == "breed-remote-linux-amd64")
    }

    @Test("Info-dictionary decode rejects a missing, blank, or undecodable manifest")
    func infoDictionaryDecodeRejectsInvalid() {
        #expect(WorkspaceRemoteDaemonManifest(infoDictionary: nil) == nil)
        #expect(WorkspaceRemoteDaemonManifest(infoDictionary: [:]) == nil)
        #expect(WorkspaceRemoteDaemonManifest(infoDictionary: [
            WorkspaceRemoteDaemonManifest.infoDictionaryKey: "   \n ",
        ]) == nil)
        #expect(WorkspaceRemoteDaemonManifest(infoDictionary: [
            WorkspaceRemoteDaemonManifest.infoDictionaryKey: "{not json",
        ]) == nil)
    }
}
