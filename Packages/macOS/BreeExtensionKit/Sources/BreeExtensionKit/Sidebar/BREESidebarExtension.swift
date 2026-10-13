@_exported import ExtensionFoundation
@_exported import ExtensionKit
import SwiftUI

/// Current state of the connection between a sidebar extension and BREE.
public enum BreeSidebarConnectionStatus: Equatable, Sendable {
    /// The extension is connected and receiving host updates.
    case connected

    /// The extension has no active BREE host connection yet.
    case waitingForHost

    /// The host connection reported an error message suitable for diagnostics.
    case error(String)
}

/// A SwiftUI sidebar extension hosted by BREE.
///
/// Conform to this protocol from your `@main` app extension type. The SDK
/// supplies the ExtensionKit configuration, scene, and XPC wiring. Your
/// extension supplies the manifest, SwiftUI body, and snapshot update handling.
@MainActor
public protocol BreeSidebarExtension: AppExtension, AnyObject where Configuration == AppExtensionSceneConfiguration {
    /// Manifest describing this sidebar extension and the data/actions it requests.
    static var manifest: BreeExtensionManifest { get }

    /// SwiftUI content rendered inside the extension scene.
    associatedtype Body: View

    /// The view BREE hosts for this extension.
    @ViewBuilder var body: Body { get }

    /// Called whenever BREE sends a new filtered sidebar snapshot.
    func update(context: BreeSidebarContext)

    /// Called when the BREE host connection changes state or reports an error.
    func connectionStatusDidChange(_ status: BreeSidebarConnectionStatus)

}

public extension BreeSidebarExtension {
    /// ExtensionKit configuration for the BREE sidebar extension point.
    ///
    /// Extension authors should not implement this unless they are deliberately
    /// replacing the SDK's ExtensionKit scene wiring.
    var configuration: AppExtensionSceneConfiguration {
        AppExtensionSceneConfiguration(BreeSidebarExtensionScene(self))
    }

    func connectionStatusDidChange(_ status: BreeSidebarConnectionStatus) {}
}
