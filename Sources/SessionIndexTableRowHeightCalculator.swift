import AppKit
import CmuxFoundation

/// Computes Vault table heights without instantiating offscreen SwiftUI rows.
@MainActor
final class SessionIndexTableRowHeightCalculator {
    private var fontHeightByPointSize: [CGFloat: CGFloat] = [:]

    func height(
        for row: SessionIndexTableRow,
        environment: SessionIndexTableEnvironmentSnapshot
    ) -> CGFloat {
        switch row {
        case .gap:
            return 4
        case .section(let section, let rowLimit, _, _, let isCollapsed, _, _, _):
            let headerHeight = lineHeight(
                role: .title,
                minimumContentHeight: SessionIndexRowMetrics.sectionIconSize,
                verticalPadding: 6,
                environment: environment
            )
            guard !isCollapsed else { return headerHeight }

            let entryHeight = lineHeight(
                role: .body,
                // The primary line is the title text or the bare agent glyph,
                // whichever is taller; there is no icon tile to reserve.
                minimumContentHeight: SessionIndexRowMetrics.agentIconSize,
                verticalPadding: SessionIndexRowMetrics.verticalPadding * 2,
                environment: environment
            )
            // Default rows in every grouping can carry a second subtitle line
            // (folder · branch); compact rows remove it before this snapshot
            // reaches the calculator.
            let subtitleHeight = lineHeight(
                role: .caption,
                minimumContentHeight: 0,
                verticalPadding: 1,
                environment: environment
            )
            var visibleEntryHeight: CGFloat = 0
            for entry in section.entries.prefix(rowLimit) {
                visibleEntryHeight += entryHeight
                if section.accessories[entry.id]?.hasSubtitle == true {
                    // SessionRow stacks its primary and detail lines with
                    // `detailLineSpacing` between them.
                    visibleEntryHeight += SessionIndexRowMetrics.detailLineSpacing + subtitleHeight
                }
            }
            let showMoreHeight: CGFloat
            if section.shouldOfferShowMore(rowLimit: rowLimit) {
                showMoreHeight = lineHeight(
                    role: .secondary,
                    minimumContentHeight: 0,
                    verticalPadding: 8,
                    environment: environment
                )
            } else {
                showMoreHeight = 0
            }
            return headerHeight + visibleEntryHeight + showMoreHeight + 2
        }
    }

    private func lineHeight(
        role: BreeTextRole,
        minimumContentHeight: CGFloat,
        verticalPadding: CGFloat,
        environment: SessionIndexTableEnvironmentSnapshot
    ) -> CGFloat {
        let pointSize = BreeType.spec(
            role,
            interfaceSize: environment.interfaceTextSize,
            magnificationPercent: environment.globalFontMagnificationPercent
        ).size
        let fontHeight: CGFloat
        if let cachedFontHeight = fontHeightByPointSize[pointSize] {
            fontHeight = cachedFontHeight
        } else {
            fontHeight = NSFont.systemFont(ofSize: pointSize).boundingRectForFont.height
            fontHeightByPointSize[pointSize] = fontHeight
        }
        return ceil(max(fontHeight, minimumContentHeight) + verticalPadding)
    }
}
