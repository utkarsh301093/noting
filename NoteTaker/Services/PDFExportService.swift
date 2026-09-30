import UIKit
import PencilKit
import PDFKit

/// Service to export notebooks and annotated PDFs into flattened PDF files or high-res images.
@MainActor
public final class PDFExportService {
    public static let shared = PDFExportService()
    
    private init() {}
    
    /// Exports the full document into a flattened PDF file stored at a temporary URL.
    ///
    /// Drawings are stored in `PageGeometry`'s logical space and scaled onto each output page.
    /// PDF pages keep their original size; if a page has margin notes, the page is widened to include them.
    public func exportDocumentToPDF(
        document: NoteDocument,
        store: DocumentStore
    ) -> URL? {
        let tempDir = FileManager.default.temporaryDirectory
        let safeTitle = document.title
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
        let exportURL = tempDir.appendingPathComponent("\(safeTitle.isEmpty ? "Notes" : safeTitle).pdf")
        try? FileManager.default.removeItem(at: exportURL)
        
        let defaultBounds = CGRect(origin: .zero, size: PageGeometry.notebookSize)
        let pdfRenderer = UIGraphicsPDFRenderer(bounds: defaultBounds)
        
        var originalPDFDoc: PDFDocument? = nil
        if let pdfFileName = document.pdfFileName {
            originalPDFDoc = PDFDocument(url: store.pdfURL(for: pdfFileName))
        }
        
        // Exports always use light-mode paper and ink, regardless of the current app theme.
        let lightTraits = UITraitCollection(userInterfaceStyle: .light)
        
        do {
            try pdfRenderer.writePDF(to: exportURL) { context in
                for page in document.pages {
                    let pdfPage = page.pdfPageIndex.flatMap { originalPDFDoc?.page(at: $0) }
                    let logicalSize = pdfPage != nil ? PageGeometry.logicalSize(for: pdfPage) : PageGeometry.notebookSize
                    let pageSize = pdfPage.map { PageGeometry.displayBounds(of: $0) } ?? PageGeometry.notebookSize
                    let scale = pageSize.width / logicalSize.width
                    
                    let marginDrawing = pdfPage != nil ? store.loadMarginDrawing(for: page) : PKDrawing()
                    let hasMargin = !marginDrawing.strokes.isEmpty
                    let marginWidth = hasMargin ? PageGeometry.marginLogicalWidth * scale : 0
                    
                    let pageRect = CGRect(origin: .zero, size: pageSize)
                    context.beginPage(withBounds: CGRect(x: 0, y: 0, width: pageSize.width + marginWidth, height: pageSize.height), pageInfo: [:])
                    let cgContext = context.cgContext
                    
                    // 1. Background (original PDF page or paper template)
                    if let pdfPage = pdfPage {
                        cgContext.setFillColor(UIColor.white.cgColor)
                        cgContext.fill(pageRect)
                        // PDFKit draws in PDF (bottom-left origin) coordinates
                        cgContext.saveGState()
                        cgContext.translateBy(x: 0, y: pageSize.height)
                        cgContext.scaleBy(x: 1.0, y: -1.0)
                        pdfPage.draw(with: .cropBox, to: cgContext)
                        cgContext.restoreGState()
                    } else {
                        cgContext.saveGState()
                        cgContext.scaleBy(x: scale, y: scale)
                        drawPaperBackground(
                            in: cgContext,
                            bounds: CGRect(origin: .zero, size: logicalSize),
                            template: page.templateType,
                            paperColor: page.paperColor
                        )
                        cgContext.restoreGState()
                    }
                    
                    // 2. Handwriting
                    let drawing = store.loadDrawing(for: page)
                    if !drawing.strokes.isEmpty {
                        lightTraits.performAsCurrent {
                            let image = drawing.image(from: CGRect(origin: .zero, size: logicalSize), scale: max(2.0, scale * 2.0))
                            image.draw(in: pageRect)
                        }
                    }
                    
                    // 3. Margin notes beside PDF pages
                    if hasMargin {
                        let marginLogical = CGSize(width: PageGeometry.marginLogicalWidth, height: logicalSize.height)
                        let marginRect = CGRect(x: pageSize.width, y: 0, width: marginWidth, height: pageSize.height)
                        cgContext.saveGState()
                        cgContext.translateBy(x: pageSize.width, y: 0)
                        cgContext.scaleBy(x: scale, y: scale)
                        drawPaperBackground(
                            in: cgContext,
                            bounds: CGRect(origin: .zero, size: marginLogical),
                            template: .dotGrid,
                            paperColor: .ivory
                        )
                        cgContext.restoreGState()
                        
                        cgContext.setStrokeColor(UIColor(FolioTheme.LightPalette.accent).cgColor)
                        cgContext.setLineWidth(1)
                        cgContext.move(to: CGPoint(x: pageSize.width, y: 0))
                        cgContext.addLine(to: CGPoint(x: pageSize.width, y: pageSize.height))
                        cgContext.strokePath()
                        
                        lightTraits.performAsCurrent {
                            let image = marginDrawing.image(from: CGRect(origin: .zero, size: marginLogical), scale: max(2.0, scale * 2.0))
                            image.draw(in: marginRect)
                        }
                    }
                }
            }
            return exportURL
        } catch {
            print("Failed to export PDF: \(error)")
            return nil
        }
    }
    
    /// Renders paper background templates directly into CoreGraphics context.
    private func drawPaperBackground(
        in context: CGContext,
        bounds: CGRect,
        template: PaperTemplateType,
        paperColor: PaperColor
    ) {
        // Fill paper color
        context.setFillColor(paperColor.uiColor.cgColor)
        context.fill(bounds)
        
        context.saveGState()
        
        let rulingUIColor = UIColor(paperColor.rulingColor)
        context.setStrokeColor(rulingUIColor.cgColor)
        context.setLineWidth(1.0)
        
        let lineHeight = template.lineHeight
        let marginX: CGFloat = 80.0
        
        switch template {
        case .blank:
            break
            
        case .ruled, .ruledNarrow:
            // Horizontal lines
            var y = lineHeight * 2
            while y < bounds.height - 40 {
                context.move(to: CGPoint(x: 0, y: y))
                context.addLine(to: CGPoint(x: bounds.width, y: y))
                y += lineHeight
            }
            context.strokePath()
            
            // Left margin line
            context.setStrokeColor(UIColor(BrandTheme.paperMarginRed).withAlphaComponent(0.6).cgColor)
            context.setLineWidth(1.5)
            context.move(to: CGPoint(x: marginX, y: 0))
            context.addLine(to: CGPoint(x: marginX, y: bounds.height))
            context.strokePath()
            
        case .grid:
            let step: CGFloat = 24.0
            // Vertical lines
            var x: CGFloat = step
            while x < bounds.width {
                context.move(to: CGPoint(x: x, y: 0))
                context.addLine(to: CGPoint(x: x, y: bounds.height))
                x += step
            }
            // Horizontal lines
            var y: CGFloat = step
            while y < bounds.height {
                context.move(to: CGPoint(x: 0, y: y))
                context.addLine(to: CGPoint(x: bounds.width, y: y))
                y += step
            }
            context.strokePath()
            
        case .dotGrid:
            let step: CGFloat = 24.0
            let dotRadius: CGFloat = 1.2
            context.setFillColor(rulingUIColor.cgColor)
            var y: CGFloat = step
            while y < bounds.height {
                var x: CGFloat = step
                while x < bounds.width {
                    context.fillEllipse(in: CGRect(x: x - dotRadius, y: y - dotRadius, width: dotRadius * 2, height: dotRadius * 2))
                    x += step
                }
                y += step
            }
            
        case .cornell:
            let cueColumnWidth: CGFloat = 180.0
            let summaryHeight: CGFloat = 160.0
            let topHeaderHeight: CGFloat = 70.0
            
            // Main ruled lines in note taking area
            var y = topHeaderHeight + lineHeight
            while y < bounds.height - summaryHeight {
                context.move(to: CGPoint(x: cueColumnWidth, y: y))
                context.addLine(to: CGPoint(x: bounds.width, y: y))
                y += lineHeight
            }
            context.strokePath()
            
            // Prominent Cornell Dividers
            context.setStrokeColor(UIColor(BrandTheme.brandPurple).withAlphaComponent(0.7).cgColor)
            context.setLineWidth(2.0)
            // Header divider
            context.move(to: CGPoint(x: 0, y: topHeaderHeight))
            context.addLine(to: CGPoint(x: bounds.width, y: topHeaderHeight))
            // Cue column divider
            context.move(to: CGPoint(x: cueColumnWidth, y: topHeaderHeight))
            context.addLine(to: CGPoint(x: cueColumnWidth, y: bounds.height - summaryHeight))
            // Summary area divider
            context.move(to: CGPoint(x: 0, y: bounds.height - summaryHeight))
            context.addLine(to: CGPoint(x: bounds.width, y: bounds.height - summaryHeight))
            context.strokePath()
            
        case .financialLedger:
            let col1: CGFloat = bounds.width * 0.45
            let col2: CGFloat = bounds.width * 0.72
            
            // Horizontal lines
            var y = lineHeight * 2
            while y < bounds.height - 40 {
                context.move(to: CGPoint(x: 0, y: y))
                context.addLine(to: CGPoint(x: bounds.width, y: y))
                y += lineHeight
            }
            context.strokePath()
            
            // Vertical ledger separators
            context.setStrokeColor(UIColor(BrandTheme.financeTeal).withAlphaComponent(0.6).cgColor)
            context.setLineWidth(1.5)
            context.move(to: CGPoint(x: col1, y: 0))
            context.addLine(to: CGPoint(x: col1, y: bounds.height))
            context.move(to: CGPoint(x: col2, y: 0))
            context.addLine(to: CGPoint(x: col2, y: bounds.height))
            context.strokePath()
            
        case .slideNotes:
            let slideHeight: CGFloat = bounds.height * 0.42
            let slideMargin: CGFloat = 40.0
            let slideRect = CGRect(x: slideMargin, y: 50, width: bounds.width - slideMargin * 2, height: slideHeight)
            
            // Slide border
            context.setStrokeColor(UIColor(BrandTheme.slateGray).withAlphaComponent(0.5).cgColor)
            context.setLineWidth(1.5)
            context.stroke(slideRect)
            
            // Ruled lines below slide
            context.setStrokeColor(rulingUIColor.cgColor)
            context.setLineWidth(1.0)
            var y = slideRect.maxY + lineHeight * 1.5
            while y < bounds.height - 40 {
                context.move(to: CGPoint(x: slideMargin, y: y))
                context.addLine(to: CGPoint(x: bounds.width - slideMargin, y: y))
                y += lineHeight
            }
            context.strokePath()
        }
        
        context.restoreGState()
    }
}
