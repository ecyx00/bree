import BreeFoundation

/// Keeps census identities attached to its immutable projection for later enrichment.
struct BreeTopProcessCapture: Sendable {
    let listing: DarwinProcessListing
    let snapshot: BreeTopProcessSnapshot
    let fields: BreeTopProcessFields
}
