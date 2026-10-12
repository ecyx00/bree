import CoreGraphics
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Right sidebar mode tab widths")
struct RightSidebarModeBarTabWidthsTests {
    private let natural: [CGFloat] = [60, 56, 62, 58, 64]
    private let floors: [CGFloat] = [30, 30, 30, 30, 30]

    @Test("A wide bar gives every tab its full label and leaves the rest empty")
    func wideBarStopsAtFullLabels() {
        let widths = RightSidebarModeBarTabWidths(natural: natural, floors: floors, selected: 4, available: 600).widths
        #expect(widths == natural)
    }

    // natural sum of the four unselected tabs: 60 + 56 + 62 + 58 = 236; selected is 64.
    @Test("Unselected labels that fit exactly all keep their full label")
    func unselectedFitExactly() {
        let widths = RightSidebarModeBarTabWidths(natural: natural, floors: floors, selected: 4, available: 300).widths
        #expect(widths == natural)
    }

    @Test("Unselected labels that miss by one point all drop to their floor")
    func unselectedMissByOne() {
        let widths = RightSidebarModeBarTabWidths(natural: natural, floors: floors, selected: 4, available: 299).widths
        #expect(widths[4] == 64)
        #expect(widths.prefix(4).allSatisfy { $0 == 30 })
    }

    @Test("The selected tab keeps its full label even when the bar is too small")
    func selectedStaysWhole() {
        let widths = RightSidebarModeBarTabWidths(natural: natural, floors: floors, selected: 4, available: 40).widths
        #expect(widths[4] == 64)
        #expect(widths.prefix(4).allSatisfy { $0 == 30 })
    }

    @Test("A wider floor never exceeds the natural width it replaces")
    func widerFloor() {
        let widths = RightSidebarModeBarTabWidths(natural: natural, floors: [30, 50, 30, 30, 30], selected: 4, available: 214).widths
        #expect(widths == [30, 50, 30, 30, 64])
    }

    @Test("Without a selected tab the labels are all-or-nothing too")
    func noSelection() {
        let fits = RightSidebarModeBarTabWidths(natural: natural, floors: floors, selected: nil, available: 300).widths
        #expect(fits == natural)
        let misses = RightSidebarModeBarTabWidths(natural: natural, floors: floors, selected: nil, available: 299).widths
        #expect(misses == floors)
    }
}
