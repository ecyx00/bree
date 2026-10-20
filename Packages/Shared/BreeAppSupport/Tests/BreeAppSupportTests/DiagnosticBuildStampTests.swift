import Testing
@testable import BreeAppSupport

@Suite struct DiagnosticBuildStampTests {
    @Test func includesSignedTagAndShaWithoutRuntimeInput() {
        let stamp = DiagnosticReport.buildStamp(infoDictionary: [
            "CFBundleName": "bree",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "42",
            "BREEDevTag": "netrel",
            "BREEGitSHA": "0123456789abcdef",
        ])

        #expect(stamp == "bree 1.2.3 (42) tag netrel sha 0123456789ab")
    }

    @Test func removesUnsafeBundleMetadata() {
        let stamp = DiagnosticReport.buildStamp(infoDictionary: [
            "CFBundleName": "bree/unsafe",
            "CFBundleShortVersionString": "1\n2",
            "CFBundleVersion": "7",
            "BREEDevTag": "tag with spaces",
            "BREEGitSHA": "abcdef",
        ])

        #expect(!stamp.contains("/"))
        #expect(!stamp.contains("\n"))
        #expect(stamp.contains("sha abcdef"))
    }
}
