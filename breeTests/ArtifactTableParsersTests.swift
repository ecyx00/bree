import XCTest

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

final class ArtifactTableParsersTests: XCTestCase {
    private func csv(_ text: String, delimiter: UInt8 = UInt8(ascii: ","), maxRows: Int = 10) -> ArtifactCSVParser.Result {
        ArtifactCSVParser.parse(Data(text.utf8), delimiter: delimiter, maxRows: maxRows)
    }

    func testCSVHeaderAndRows() {
        let result = csv("a,b\n1,2\n3,4\n")
        XCTAssertEqual(result.header, ["a", "b"])
        XCTAssertEqual(result.rows, [["1", "2"], ["3", "4"]])
        XCTAssertFalse(result.truncated)
    }

    func testCSVQuotedFieldsEscapesAndCRLF() {
        let result = csv("name,note\r\n\"Doe, J\",\"say \"\"hi\"\"\nthere\"\r\nx,\r\n")
        XCTAssertEqual(result.rows, [["Doe, J", "say \"hi\"\nthere"], ["x", ""]])
    }

    func testCSVTabDelimiterAndBOMAndNoTrailingNewline() {
        let result = ArtifactCSVParser.parse(Data([0xEF, 0xBB, 0xBF] + Array("a\tb\n1\t2".utf8)), delimiter: UInt8(ascii: "\t"))
        XCTAssertEqual(result.header, ["a", "b"])
        XCTAssertEqual(result.rows, [["1", "2"]])
    }

    func testCSVSkipsBlankLinesAndHandlesEmpty() {
        XCTAssertEqual(csv("a\n\n1\n").rows, [["1"]])
        XCTAssertEqual(csv("").header, [])
    }

    func testCSVCapsRowsAndFlagsTruncation() {
        let text = "h\n" + (1...25).map(String.init).joined(separator: "\n") + "\n"
        let result = csv(text, maxRows: 10)
        XCTAssertEqual(result.rows.count, 10)
        XCTAssertTrue(result.truncated)
        XCTAssertFalse(csv("h\n1\n2\n", maxRows: 2).truncated)
    }

    func testJSONLPrettyPrintsAndNumbersLines() {
        let result = ArtifactJSONLParser.parse(Data("{\"b\":1,\"a\":[1]}\n\n42\n".utf8))
        XCTAssertEqual(result.records.map(\.lineNumber), [1, 3])
        XCTAssertTrue(result.records.allSatisfy(\.isValid))
        XCTAssertTrue(result.records[0].text.contains("\n"))
        XCTAssertEqual(result.records[1].text, "42")
        XCTAssertFalse(result.truncated)
    }

    func testJSONLFlagsInvalidLinesInline() {
        let result = ArtifactJSONLParser.parse(Data("{\"ok\":true}\n{broken\n{\"ok\":false}".utf8))
        XCTAssertEqual(result.records.map(\.isValid), [true, false, true])
        XCTAssertEqual(result.records[1].text, "{broken")
        XCTAssertEqual(result.records[1].lineNumber, 2)
    }

    func testJSONLCapsRecords() {
        let text = (1...12).map { "{\"n\":\($0)}" }.joined(separator: "\n")
        let result = ArtifactJSONLParser.parse(Data(text.utf8), maxRecords: 5)
        XCTAssertEqual(result.records.count, 5)
        XCTAssertTrue(result.truncated)
    }
}
