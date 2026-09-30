import Foundation

/// Represents a single page within a notebook or an annotated PDF.
public struct NotePage: Identifiable, Codable, Equatable {
    public let id: UUID
    public let documentId: UUID
    public var pageIndex: Int
    public var templateType: PaperTemplateType
    public var paperColor: PaperColor
    public var drawingDataFileName: String
    public var pdfPageIndex: Int?
    public var isBookmarked: Bool
    public var createdDate: Date
    public var updatedDate: Date
    
    public init(
        id: UUID = UUID(),
        documentId: UUID,
        pageIndex: Int,
        templateType: PaperTemplateType = .ruled,
        paperColor: PaperColor = .ivory,
        pdfPageIndex: Int? = nil,
        isBookmarked: Bool = false,
        createdDate: Date = Date(),
        updatedDate: Date = Date()
    ) {
        self.id = id
        self.documentId = documentId
        self.pageIndex = pageIndex
        self.templateType = templateType
        self.paperColor = paperColor
        self.drawingDataFileName = "\(id.uuidString).drawing"
        self.pdfPageIndex = pdfPageIndex
        self.isBookmarked = isBookmarked
        self.createdDate = createdDate
        self.updatedDate = updatedDate
    }

    /// Drawing file for the side margin shown next to PDF pages.
    public var marginDrawingFileName: String {
        "\(id.uuidString)-margin.drawing"
    }
}
