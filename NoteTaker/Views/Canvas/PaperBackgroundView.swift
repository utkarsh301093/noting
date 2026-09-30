import SwiftUI

/// High-performance vector background renderer for notebook pages and paper templates.
public struct PaperBackgroundView: View {
    public let templateType: PaperTemplateType
    public let paperColor: PaperColor
    /// On-screen points per logical point; matches the drawing canvas above it so rulings line up with ink.
    public let contentScale: CGFloat
    /// Full logical page size, when only part of the page is shown (Zoom Window). Nil = the view is the whole page.
    public let pageSize: CGSize?
    /// Logical point shown at the view's top-left corner.
    public let visibleOrigin: CGPoint

    public init(
        templateType: PaperTemplateType,
        paperColor: PaperColor,
        contentScale: CGFloat = 1.0,
        pageSize: CGSize? = nil,
        visibleOrigin: CGPoint = .zero
    ) {
        self.templateType = templateType
        self.paperColor = paperColor
        self.contentScale = max(contentScale, 0.05)
        self.pageSize = pageSize
        self.visibleOrigin = visibleOrigin
    }

    public var body: some View {
        Canvas { context, displaySize in
            context.scaleBy(x: contentScale, y: contentScale)
            context.translateBy(x: -visibleOrigin.x, y: -visibleOrigin.y)
            let size = pageSize ?? CGSize(width: displaySize.width / contentScale, height: displaySize.height / contentScale)
            let bounds = CGRect(origin: .zero, size: size)
            
            // 1. Fill Background
            context.fill(Path(bounds), with: .color(paperColor.backgroundColor))
            
            let rulingColor = paperColor.rulingColor
            let lineHeight = templateType.lineHeight
            let marginX: CGFloat = 80.0
            
            switch templateType {
            case .blank:
                break
                
            case .ruled, .ruledNarrow:
                // Horizontal ruled lines
                var linePath = Path()
                var y = lineHeight * 2
                while y < size.height - 40 {
                    linePath.move(to: CGPoint(x: 0, y: y))
                    linePath.addLine(to: CGPoint(x: size.width, y: y))
                    y += lineHeight
                }
                context.stroke(linePath, with: .color(rulingColor), lineWidth: 1.0)
                
                // Red/Pink left margin
                var marginPath = Path()
                marginPath.move(to: CGPoint(x: marginX, y: 0))
                marginPath.addLine(to: CGPoint(x: marginX, y: size.height))
                context.stroke(marginPath, with: .color(BrandTheme.paperMarginRed.opacity(0.6)), lineWidth: 1.5)
                
            case .grid:
                let step: CGFloat = 24.0
                var gridPath = Path()
                var x: CGFloat = step
                while x < size.width {
                    gridPath.move(to: CGPoint(x: x, y: 0))
                    gridPath.addLine(to: CGPoint(x: x, y: size.height))
                    x += step
                }
                var y: CGFloat = step
                while y < size.height {
                    gridPath.move(to: CGPoint(x: 0, y: y))
                    gridPath.addLine(to: CGPoint(x: size.width, y: y))
                    y += step
                }
                context.stroke(gridPath, with: .color(rulingColor), lineWidth: 0.8)
                
            case .dotGrid:
                let step: CGFloat = 24.0
                let dotRadius: CGFloat = 1.2
                var y: CGFloat = step
                while y < size.height {
                    var x: CGFloat = step
                    while x < size.width {
                        let dotRect = CGRect(x: x - dotRadius, y: y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
                        context.fill(Path(ellipseIn: dotRect), with: .color(rulingColor))
                        x += step
                    }
                    y += step
                }
                
            case .cornell:
                let cueColumnWidth: CGFloat = 180.0
                let summaryHeight: CGFloat = 160.0
                let topHeaderHeight: CGFloat = 70.0
                
                // Ruled lines in note section
                var notesPath = Path()
                var y = topHeaderHeight + lineHeight
                while y < size.height - summaryHeight {
                    notesPath.move(to: CGPoint(x: cueColumnWidth, y: y))
                    notesPath.addLine(to: CGPoint(x: size.width, y: y))
                    y += lineHeight
                }
                context.stroke(notesPath, with: .color(rulingColor), lineWidth: 1.0)
                
                // Prominent Cornell Structural Dividers
                var dividerPath = Path()
                // Header divider
                dividerPath.move(to: CGPoint(x: 0, y: topHeaderHeight))
                dividerPath.addLine(to: CGPoint(x: size.width, y: topHeaderHeight))
                // Cue column divider
                dividerPath.move(to: CGPoint(x: cueColumnWidth, y: topHeaderHeight))
                dividerPath.addLine(to: CGPoint(x: cueColumnWidth, y: size.height - summaryHeight))
                // Summary divider
                dividerPath.move(to: CGPoint(x: 0, y: size.height - summaryHeight))
                dividerPath.addLine(to: CGPoint(x: size.width, y: size.height - summaryHeight))
                
                context.stroke(dividerPath, with: .color(BrandTheme.brandPurple.opacity(0.7)), lineWidth: 2.0)
                
            case .financialLedger:
                let col1: CGFloat = size.width * 0.45
                let col2: CGFloat = size.width * 0.72
                
                // Horizontal lines
                var linesPath = Path()
                var y = lineHeight * 2
                while y < size.height - 40 {
                    linesPath.move(to: CGPoint(x: 0, y: y))
                    linesPath.addLine(to: CGPoint(x: size.width, y: y))
                    y += lineHeight
                }
                context.stroke(linesPath, with: .color(rulingColor), lineWidth: 1.0)
                
                // Vertical columns
                var colsPath = Path()
                colsPath.move(to: CGPoint(x: col1, y: 0))
                colsPath.addLine(to: CGPoint(x: col1, y: size.height))
                colsPath.move(to: CGPoint(x: col2, y: 0))
                colsPath.addLine(to: CGPoint(x: col2, y: size.height))
                context.stroke(colsPath, with: .color(BrandTheme.financeTeal.opacity(0.6)), lineWidth: 1.5)
                
            case .slideNotes:
                let slideHeight: CGFloat = size.height * 0.42
                let slideMargin: CGFloat = 40.0
                let slideRect = CGRect(x: slideMargin, y: 50, width: size.width - slideMargin * 2, height: slideHeight)
                
                // Slide outline
                context.stroke(Path(roundedRect: slideRect, cornerRadius: 8), with: .color(BrandTheme.slateGray.opacity(0.4)), lineWidth: 1.5)
                
                // Lines below
                var linesPath = Path()
                var y = slideRect.maxY + lineHeight * 1.5
                while y < size.height - 40 {
                    linesPath.move(to: CGPoint(x: slideMargin, y: y))
                    linesPath.addLine(to: CGPoint(x: size.width - slideMargin, y: y))
                    y += lineHeight
                }
                context.stroke(linesPath, with: .color(rulingColor), lineWidth: 1.0)
            }
        }
    }
}
