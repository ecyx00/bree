public import SwiftUI

/// SwiftUI bridge for appearance-resolved AppKit icons.
@MainActor
public struct BreeResolvedIconImage: NSViewRepresentable {
    public let request: BreeResolvedIconRequest?

    /// Creates a SwiftUI icon backed by ``BreeResolvedIconImageView``.
    public init(request: BreeResolvedIconRequest?) {
        self.request = request
    }

    public func makeNSView(context: Context) -> BreeResolvedIconImageView {
        BreeResolvedIconImageView(frame: .zero)
    }

    public func updateNSView(_ nsView: BreeResolvedIconImageView, context: Context) {
        nsView.apply(request)
    }
}
