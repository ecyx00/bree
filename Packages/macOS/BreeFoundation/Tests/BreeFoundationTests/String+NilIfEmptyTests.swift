import Testing

@testable import BreeFoundation

@Suite struct StringNilIfEmptyTests {
    @Test func emptyStringBecomesNil() {
        #expect("".nilIfEmpty == nil)
    }

    @Test func nonEmptyStringPassesThrough() {
        #expect("bree".nilIfEmpty == "bree")
    }

    @Test func whitespaceIsNotEmpty() {
        // nilIfEmpty only checks isEmpty; a space is non-empty and passes through.
        #expect(" ".nilIfEmpty == " ")
    }
}
