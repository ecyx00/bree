import Foundation
import Testing
@testable import BreeFoundation

struct JSONObjectLineScannerTests {
    private func scan(_ text: String) -> JSONObjectLineScanner.Fields? {
        Array(text.utf8).withUnsafeBufferPointer { JSONObjectLineScanner.scan($0) }
    }

    @Test("Reads top-level seq and type")
    func topLevel() {
        let fields = scan(#"{"a":1,"payload":{"seq":9,"type":"event"},"seq":42,"type":"event"}"#)
        #expect(fields == .init(sequence: 42, typeIsEvent: true))
    }

    @Test("Nested seq never shadows the top-level field")
    func nestedIgnored() {
        let fields = scan(#"{"payload":{"seq":9,"x":[1,{"seq":7}]},"type":"other","seq":3}"#)
        #expect(fields == .init(sequence: 3, typeIsEvent: false))
    }

    @Test("Strings with braces and escapes are skipped")
    func stringsSkipped() {
        let fields = scan(#"{"t":"}\"{,","seq":5,"type":"event"}"#)
        #expect(fields == .init(sequence: 5, typeIsEvent: true))
    }

    @Test("Non-integer or missing seq is reported as nil")
    func nonInteger() {
        #expect(scan(#"{"seq":"5","type":"event"}"#) == .init(sequence: nil, typeIsEvent: true))
        #expect(scan(#"{"seq":5.5,"type":"event"}"#) == .init(sequence: nil, typeIsEvent: true))
        #expect(scan(#"{"type":"event"}"#) == .init(sequence: nil, typeIsEvent: true))
    }

    @Test("Malformed lines return nil")
    func malformed() {
        #expect(scan("not json") == nil)
        #expect(scan(#"{"seq":1"#) == nil)
        #expect(scan(#"{"seq" 1}"#) == nil)
    }

    @Test("Agrees with JSONSerialization on generated lines")
    func agreesWithFoundation() throws {
        for index in 1...200 {
            let object: [String: Any] = [
                "seq": index,
                "type": index % 7 == 0 ? "gap" : "event",
                "payload": ["seq": index + 1000, "list": [1, 2, ["seq": 5]], "s": "a}\"b{"],
                "name": "x\(index)",
            ]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let fields = data.withUnsafeBytes { raw in
                JSONObjectLineScanner.scan(raw.bindMemory(to: UInt8.self))
            }
            #expect(fields == .init(sequence: Int64(index), typeIsEvent: index % 7 != 0))
        }
    }
}
