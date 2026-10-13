/// Reads two top-level fields of one JSON object line without building any
/// Foundation objects, so a large append-only log can be indexed with a few
/// bytes per line instead of one `[String: Any]` tree per line.
public enum JSONObjectLineScanner {
    public struct Fields: Equatable, Sendable {
        /// Top-level `"seq"` when it is a plain integer number.
        public var sequence: Int64?
        /// Whether top-level `"type"` is exactly the string `"event"`.
        public var typeIsEvent: Bool
    }

    /// Returns `nil` when the line is not a well-formed-looking JSON object.
    /// Nested values are skipped structurally, so a nested `"seq"` key never
    /// shadows the top-level one. This is an index scan, not a validator:
    /// callers still decode the lines they keep with a real JSON parser.
    public static func scan(_ line: UnsafeBufferPointer<UInt8>) -> Fields? {
        var i = 0
        let n = line.count
        func skipSpace() { while i < n, line[i] == 0x20 || line[i] == 0x09 { i += 1 } }
        // Returns the byte range of a string's contents (escapes left raw).
        func readString() -> Range<Int>? {
            guard i < n, line[i] == 0x22 else { return nil }
            i += 1
            let start = i
            while i < n {
                switch line[i] {
                case 0x5C: i += 2
                case 0x22:
                    let range = start..<i
                    i += 1
                    return range
                default: i += 1
                }
            }
            return nil
        }
        func skipValue() -> Bool {
            var depth = 0
            while i < n {
                switch line[i] {
                case 0x22: guard readString() != nil else { return false }; if depth == 0 { return true }; continue
                case 0x7B, 0x5B: depth += 1
                case 0x7D, 0x5D:
                    if depth == 0 { return true }
                    depth -= 1
                    if depth == 0 { i += 1; return true }
                case 0x2C where depth == 0: return true
                default: break
                }
                i += 1
            }
            return depth == 0
        }
        func matches(_ range: Range<Int>, _ text: StaticString) -> Bool {
            guard range.count == text.utf8CodeUnitCount else { return false }
            let bytes = text.utf8Start
            for offset in 0..<range.count where line[range.lowerBound + offset] != bytes[offset] { return false }
            return true
        }

        skipSpace()
        guard i < n, line[i] == 0x7B else { return nil }
        i += 1
        var fields = Fields(sequence: nil, typeIsEvent: false)
        while true {
            skipSpace()
            guard i < n else { return nil }
            if line[i] == 0x7D { return fields }
            if line[i] == 0x2C { i += 1; continue }
            guard let key = readString() else { return nil }
            skipSpace()
            guard i < n, line[i] == 0x3A else { return nil }
            i += 1
            skipSpace()
            guard i < n else { return nil }
            if matches(key, "seq") {
                var j = i
                var negative = false
                if j < n, line[j] == 0x2D { negative = true; j += 1 }
                var value: Int64 = 0
                let digitsStart = j
                while j < n, line[j] >= 0x30, line[j] <= 0x39 {
                    let (m, o1) = value.multipliedReportingOverflow(by: 10)
                    let (a, o2) = m.addingReportingOverflow(Int64(line[j] - 0x30))
                    guard !o1, !o2 else { return nil }
                    value = a
                    j += 1
                }
                // Fractions and exponents are not plain integers.
                if j == digitsStart || (j < n && (line[j] == 0x2E || line[j] == 0x65 || line[j] == 0x45)) {
                    fields.sequence = nil
                } else {
                    fields.sequence = negative ? -value : value
                }
            } else if matches(key, "type"), line[i] == 0x22 {
                let save = i
                guard let range = readString() else { return nil }
                fields.typeIsEvent = matches(range, "event")
                i = save
            }
            guard skipValue() else { return nil }
        }
    }
}
