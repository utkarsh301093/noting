import CoreGraphics
import PDFKit

/// Fixed, device-independent coordinate space that page drawings are stored in.
/// Canvases are scaled to fit the screen, so strokes stay aligned with the page
/// across rotation, margin toggling, different iPads, and PDF export.
public enum PageGeometry {
    public static let logicalWidth: CGFloat = 768
    public static let notebookAspect: CGFloat = 1.30
    public static let marginLogicalWidth: CGFloat = 320

    public static var notebookSize: CGSize {
        CGSize(width: logicalWidth, height: logicalWidth * notebookAspect)
    }

    /// Visible size of a PDF page (crop box, with the page's rotation applied).
    public static func displayBounds(of page: PDFPage) -> CGSize {
        let box = page.bounds(for: .cropBox)
        var size = CGSize(width: box.width, height: box.height)
        if page.rotation % 180 != 0 {
            size = CGSize(width: size.height, height: size.width)
        }
        return size
    }

    /// Logical canvas size for a PDF page: fixed width, height from the page's real aspect ratio.
    public static func logicalSize(for page: PDFPage?) -> CGSize {
        guard let page = page else { return notebookSize }
        let bounds = displayBounds(of: page)
        guard bounds.width > 0, bounds.height > 0 else { return notebookSize }
        return CGSize(width: logicalWidth, height: logicalWidth * bounds.height / bounds.width)
    }
}
