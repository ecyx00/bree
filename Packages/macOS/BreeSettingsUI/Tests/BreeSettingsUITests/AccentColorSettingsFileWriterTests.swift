import BreeFoundation
import BreeSettings
import Foundation
import Testing

@testable import BreeSettingsUI

@MainActor
@Suite struct AccentColorSettingsFileWriterTests {
    @Test func writesTheCustomColorToBreeJSON() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("bree.json")
        let store = JSONConfigStore(fileURL: file)
        var reloads = 0
        let writer = AccentColorSettingsFileWriter(
            write: { value in
                _ = try await store.setWithReceipt(value, for: AccentColorSettingsFileWriter.settingsFileKey)
                reloads += 1
            },
            didFail: { error in Issue.record(error) }
        )

        let value = try #require(BreeAccentColorMode.settingsFileValue(mode: .custom, customHex: "ff6a00"))
        writer.request(value)
        await writer.waitUntilIdle()

        let root = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        )
        #expect((root["app"] as? [String: Any])?["accentColor"] as? String == "#FF6A00")
        #expect(reloads == 1)
        #expect(writer.requestedValue == nil)
    }

    @Test func keepsOnlyTheNewestRequestWhileAWriteIsInFlight() async {
        var written: [String] = []
        var releaseFirstWrite: CheckedContinuation<Void, Never>?
        let writer = AccentColorSettingsFileWriter(
            write: { value in
                written.append(value)
                if written.count == 1 {
                    await withCheckedContinuation { releaseFirstWrite = $0 }
                }
            },
            didFail: { error in Issue.record(error) }
        )

        writer.request("#111111")
        while releaseFirstWrite == nil { await Task.yield() }
        writer.request("#222222")
        writer.request("#333333")
        #expect(writer.requestedValue == "#333333")
        releaseFirstWrite?.resume()
        await writer.waitUntilIdle()

        #expect(written == ["#111111", "#333333"])
        #expect(writer.requestedValue == nil)
    }

    @Test func aFailedWriteIsReportedAndLaterRequestsStillRun() async {
        struct WriteFailed: Error {}
        var written: [String] = []
        var failures = 0
        let writer = AccentColorSettingsFileWriter(
            write: { value in
                if value == "system" { throw WriteFailed() }
                written.append(value)
            },
            didFail: { _ in failures += 1 }
        )

        writer.request("system")
        await writer.waitUntilIdle()
        writer.request("bree")
        await writer.waitUntilIdle()

        #expect(failures == 1)
        #expect(written == ["bree"])
    }
}
