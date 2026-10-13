import Foundation

/// A deserialized bree.json schema that validators share instead of re-parsing.
///
/// The tree is never mutated after parsing, so concurrent reads are safe.
struct BreeParsedConfigSchema: @unchecked Sendable {
    /// The schema embedded in BreeFoundation, parsed on first use.
    static let embedded = BreeParsedConfigSchema(data: BreeEmbeddedConfigSchema.data)

    let root: [String: Any]

    init(data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            preconditionFailure("bree.json schema is not a JSON object")
        }
        self.root = root
    }
}
