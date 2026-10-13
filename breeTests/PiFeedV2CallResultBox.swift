#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

/// Safety: one socket worker writes once, and the test reads only after its continuation resumes.
final class PiFeedV2CallResultBox: @unchecked Sendable {
    var value: TerminalController.V2CallResult?
}
