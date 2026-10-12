import Foundation

/// Row cap shared by the CSV table and the JSONL record list in Quick View.
enum ArtifactViewLimits {
    static let maxRows = 10_000
}

/// Minimal RFC 4180 style parser. It stops after `maxRows` data rows, so a huge
/// (memory-mapped) file is only touched up to the cap.
enum ArtifactCSVParser {
    struct Result: Equatable {
        var header: [String]
        var rows: [[String]]
        /// True when more data rows followed the cap.
        var truncated: Bool
    }

    static func parse(_ data: Data, delimiter: UInt8 = UInt8(ascii: ","), maxRows: Int = ArtifactViewLimits.maxRows) -> Result {
        data.withUnsafeBytes { raw -> Result in
            let bytes = raw.bindMemory(to: UInt8.self)
            let quote = UInt8(ascii: "\""), lf = UInt8(ascii: "\n"), cr = UInt8(ascii: "\r")
            let count = bytes.count
            var index = (count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) ? 3 : 0
            var records: [[String]] = []
            var row: [String] = []
            var field: [UInt8] = []
            var fieldStarted = false
            var inQuotes = false
            var truncated = false

            func endField() {
                row.append(String(decoding: field, as: UTF8.self))
                field.removeAll(keepingCapacity: true)
                fieldStarted = false
            }

            while index < count {
                let byte = bytes[index]
                if inQuotes {
                    if byte == quote {
                        if index + 1 < count, bytes[index + 1] == quote {
                            field.append(quote)
                            index += 1
                        } else {
                            inQuotes = false
                        }
                    } else {
                        field.append(byte)
                    }
                } else if byte == quote, !fieldStarted {
                    inQuotes = true
                    fieldStarted = true
                } else if byte == delimiter {
                    // endField() resets fieldStarted so a quote right after the
                    // delimiter opens a quoted field.
                    endField()
                } else if byte == lf || byte == cr {
                    if byte == cr, index + 1 < count, bytes[index + 1] == lf { index += 1 }
                    let blank = row.isEmpty && field.isEmpty && !fieldStarted
                    if !blank {
                        endField()
                        records.append(row)
                    }
                    row = []
                    if records.count == maxRows + 1 {
                        truncated = bytes[(index + 1)...].contains { $0 != lf && $0 != cr }
                        break
                    }
                } else {
                    field.append(byte)
                    fieldStarted = true
                }
                index += 1
            }
            if !truncated, !(row.isEmpty && field.isEmpty && !fieldStarted) {
                endField()
                records.append(row)
            }
            let header = records.first ?? []
            return Result(header: header, rows: Array(records.dropFirst()), truncated: truncated)
        }
    }
}

/// One JSON value per line. Valid lines are pretty-printed; invalid lines keep their raw text.
enum ArtifactJSONLParser {
    struct Record: Equatable, Identifiable {
        let lineNumber: Int
        let text: String
        let isValid: Bool
        var id: Int { lineNumber }
    }

    struct Result: Equatable {
        var records: [Record]
        var truncated: Bool
    }

    static func parse(_ data: Data, maxRecords: Int = ArtifactViewLimits.maxRows) -> Result {
        data.withUnsafeBytes { raw -> Result in
            let bytes = raw.bindMemory(to: UInt8.self)
            let lf = UInt8(ascii: "\n")
            var records: [Record] = []
            var lineNumber = 0
            var start = 0
            let count = bytes.count
            while start < count {
                var end = start
                while end < count, bytes[end] != lf { end += 1 }
                lineNumber += 1
                let line = Data(bytes[start..<end])
                start = end + 1
                guard line.contains(where: { $0 != UInt8(ascii: " ") && $0 != UInt8(ascii: "\t") && $0 != UInt8(ascii: "\r") }) else { continue }
                if records.count == maxRecords { return Result(records: records, truncated: true) }
                records.append(record(line: line, number: lineNumber))
            }
            return Result(records: records, truncated: false)
        }
    }

    private static func record(line: Data, number: Int) -> Record {
        if let object = try? JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed]),
           let pretty = try? JSONSerialization.data(
               withJSONObject: object,
               options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
           ) {
            return Record(lineNumber: number, text: String(decoding: pretty, as: UTF8.self), isValid: true)
        }
        let raw = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return Record(lineNumber: number, text: raw, isValid: false)
    }
}
