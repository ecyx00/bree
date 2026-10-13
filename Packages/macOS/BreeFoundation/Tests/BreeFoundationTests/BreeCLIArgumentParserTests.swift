import Testing
@testable import BreeFoundation

@Suite("bree CLI argument parser")
struct BreeCLIArgumentParserTests {
    private let parser = BreeCLIArgumentParser()

    @Test("presentation flags after a subcommand are extracted")
    func extractsPostSubcommandJSON() throws {
        let result = try parser.parse(["list", "--json", "--id-format", "both"])
        #expect(result.jsonOutput)
        #expect(result.idFormat == "both")
        #expect(result.remaining == ["list"])
    }

    @Test("command option values that look like flags are preserved")
    func preservesOptionValues() throws {
        let result = try parser.parse(["run", "--command", "--json", "--json"])
        #expect(result.jsonOutput)
        #expect(result.remaining == ["run", "--command", "--json"])
    }

    @Test("terminator stops presentation parsing")
    func honorsTerminator() throws {
        let result = try parser.parse(["run", "--", "--json"])
        #expect(!result.jsonOutput)
        #expect(result.remaining == ["run", "--", "--json"])
    }

    @Test("missing identifier format value is reported")
    func rejectsMissingIDFormatValue() {
        #expect(throws: BreeCLIArgumentParser.ParseError.missingIDFormatValue) {
            _ = try parser.parse(["list", "--id-format"])
        }
    }

    @Test("auth subcommands accept only their documented arguments")
    func parsesAuthSubcommands() {
        #expect(parser.parseAuthSubcommand([]) == "status")
        #expect(parser.parseAuthSubcommand(["status"]) == "status")
        #expect(parser.parseAuthSubcommand(["login"]) == "login")
        #expect(parser.parseAuthSubcommand(["logout"]) == "logout")
        #expect(parser.parseAuthSubcommand(["team", "use", "team-id"]) == "team")

        for args in [
            ["status", "--typo"],
            ["login", "--typo"],
            ["logout", "--typo"],
            ["team", "list", "--typo"],
        ] {
            #expect(parser.parseAuthSubcommand(args) == nil)
        }
    }
}
