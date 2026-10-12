import Foundation

/// The filesystem scope used by the Files and Find right-sidebar tools.
enum FileSearchScope: Equatable, Sendable {
    case unsupported
    case local

    /// Derives the search scope from the active file provider.
    init(provider: FileExplorerProvider?) {
        if provider is LocalFileExplorerProvider {
            self = .local
        } else {
            self = .unsupported
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.local, .local), (.unsupported, .unsupported): return true
        default: return false
        }
    }

    var debugName: String {
        switch self {
        case .unsupported: return "unsupported"
        case .local: return "local"
        }
    }

}
