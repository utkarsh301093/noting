import SwiftUI
import PDFKit

/// Renders one PDF page edge-to-edge into its frame, so annotations drawn on top line up exactly
/// with the page content. Rendering happens off the main thread and is cached.
public struct PDFPageBackgroundView: View {
    public let pdfURL: URL
    public let pageIndex: Int

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    private static let documentCache = NSCache<NSURL, PDFDocument>()

    /// Main-thread document cache, used for page geometry lookups.
    public static func cachedDocument(for url: URL) -> PDFDocument? {
        let nsURL = url as NSURL
        if let cached = documentCache.object(forKey: nsURL) {
            return cached
        }
        if let doc = PDFDocument(url: url) {
            documentCache.setObject(doc, forKey: nsURL)
            return doc
        }
        return nil
    }

    public init(pdfURL: URL, pageIndex: Int) {
        self.pdfURL = pdfURL
        self.pageIndex = pageIndex
    }

    public var body: some View {
        GeometryReader { geo in
            let pixelWidth = Int((geo.size.width * displayScale).rounded())
            ZStack {
                Color.white
                if let image = image {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.high)
                } else {
                    ProgressView()
                        .tint(.gray)
                }
            }
            .task(id: pixelWidth) {
                guard pixelWidth > 0 else { return }
                let pixelSize = CGSize(
                    width: geo.size.width * displayScale,
                    height: geo.size.height * displayScale
                )
                image = await PDFPageRenderer.shared.render(url: pdfURL, pageIndex: pageIndex, pixelSize: pixelSize)
            }
        }
    }
}

/// Serial background renderer for PDF pages with an in-memory image cache.
final class PDFPageRenderer: @unchecked Sendable {
    static let shared = PDFPageRenderer()

    private let queue = DispatchQueue(label: "folio.pdf-page-renderer", qos: .userInitiated)
    private var documents: [URL: PDFDocument] = [:] // accessed only on `queue`
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.totalCostLimit = 256 * 1024 * 1024
    }

    func render(url: URL, pageIndex: Int, pixelSize: CGSize) async -> UIImage? {
        // Cap very large renders (e.g. 13" landscape at 3x) to keep memory in check.
        let maxDimension: CGFloat = 3200
        let factor = min(1, maxDimension / max(pixelSize.width, pixelSize.height, 1))
        let size = CGSize(width: (pixelSize.width * factor).rounded(), height: (pixelSize.height * factor).rounded())
        let key = "\(url.path)#\(pageIndex)@\(Int(size.width))"

        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }

        return await withCheckedContinuation { continuation in
            queue.async {
                let document: PDFDocument?
                if let existing = self.documents[url] {
                    document = existing
                } else {
                    document = PDFDocument(url: url)
                    if self.documents.count > 8 { self.documents.removeAll() }
                    self.documents[url] = document
                }
                guard let page = document?.page(at: pageIndex), size.width > 0, size.height > 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let image = page.thumbnail(of: size, for: .cropBox)
                self.cache.setObject(image, forKey: key as NSString, cost: Int(size.width * size.height * 4))
                continuation.resume(returning: image)
            }
        }
    }
}
