import SwiftUI

struct BrowserPortalOmnibarSuggestionsConfiguration {
    let panelId: UUID
    let popupFrame: CGRect
    let colorScheme: ColorScheme
    let engineName: String
    let items: [OmnibarSuggestion]
    let selectedIndex: Int
    let onCommit: (OmnibarSuggestion) -> Void
    let onHighlight: (Int) -> Void
}
