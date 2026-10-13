import BreeFoundation
import Testing

struct RemoteClientDeviceNameTests {
    @Test(arguments: [
        ("MacBook.local", "bree-MacBook"),
        ("Austin's MacBook.local", "bree-Austin-s-MacBook"),
        ("build-box.example.com", "bree-build-box"),
        ("", "bree-mac"),
        (String(repeating: "x", count: 100), "bree-" + String(repeating: "x", count: 40))
    ])
    func keepsTheExistingRemoteLabelFormat(hostName: String, expected: String) {
        #expect(RemoteClientDeviceName(hostName: hostName).value == expected)
    }
}
