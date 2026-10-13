import Foundation

extension Notification.Name {
    /// Posted when the signed-in session's Cloud VM access ends (sign-out or account switch).
    public static let breeCloudVMAccessDidEnd = Notification.Name("bree.cloudVM.accessDidEnd")
}
