import Testing

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

@Suite(.serialized)
struct BreeSocketEventMapperTests {
    @Test
    func paneResizeEventDistinguishesAppliedFromRemoteRequested() {
        BreeEventBus.shared.resetForTesting()
        defer { BreeEventBus.shared.resetForTesting() }
        let command = #"{"id":1,"method":"pane.resize","params":{"direction":"right","amount":10}}"#
        let localResponse = #"{"id":1,"ok":true,"result":{"pane_id":"local-pane"}}"#
        let remoteResponse = #"{"id":1,"ok":true,"result":{"pane_id":"remote-pane","remote":true}}"#

        BreeSocketEventMapper.publish(command: command, response: localResponse)
        BreeSocketEventMapper.publish(command: command, response: remoteResponse)

        let events = BreeEventBus.shared.retainedSnapshot()
        #expect(events.compactMap { $0["name"] as? String } == [
            "pane.resized",
            "pane.resize_requested",
        ])
        #expect(events.compactMap { $0["pane_id"] as? String } == [
            "local-pane",
            "remote-pane",
        ])
    }
}
