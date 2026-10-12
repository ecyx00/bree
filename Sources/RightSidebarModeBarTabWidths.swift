import CoreGraphics

/// How wide each right sidebar mode tab is. The selected tab always keeps its
/// full label. The unselected tabs are all-or-nothing: if every one of their
/// full labels fits in what the selected tab leaves, they all get their full
/// width; otherwise they all drop to their floor (icon only). A tab is never
/// partly truncated, and spare width stays empty at the trailing end.
struct RightSidebarModeBarTabWidths {
    let widths: [CGFloat]

    /// - Parameters:
    ///   - natural: Each tab's width with its full label.
    ///   - floors: Each tab's smallest width (icon only).
    ///   - selected: The selected tab's index, if any.
    ///   - available: The width for all tabs, with the gaps between them removed.
    init(natural: [CGFloat], floors: [CGFloat], selected: Int?, available: CGFloat) {
        precondition(natural.count == floors.count)
        var result = floors
        var rest = max(0, available)
        var others = Array(natural.indices)
        if let selected, natural.indices.contains(selected) {
            result[selected] = max(floors[selected], natural[selected])
            rest = max(0, available - result[selected])
            others.removeAll { $0 == selected }
        }
        let othersNatural = others.reduce(CGFloat(0)) { $0 + max(floors[$1], natural[$1]) }
        if othersNatural <= rest {
            for index in others { result[index] = max(floors[index], natural[index]) }
        }
        widths = result
    }
}
