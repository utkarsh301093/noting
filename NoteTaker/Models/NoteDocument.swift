import Foundation

public enum DocumentType: String, Codable, CaseIterable {
    case notebook = "Notebook"
    case pdfDocument = "PDF Document"
    
    public var iconName: String {
        switch self {
        case .notebook: return "book.closed.fill"
        case .pdfDocument: return "doc.richtext.fill"
        }
    }
}

/// Represents a multi-page notebook or an imported PDF document.
public struct NoteDocument: Identifiable, Codable, Equatable {
    public let id: UUID
    public var title: String
    public var folderId: UUID?
    public var type: DocumentType
    public var createdDate: Date
    public var updatedDate: Date
    public var tags: [String]
    public var isFavorite: Bool
    public var coverColorHex: String
    public var defaultTemplate: PaperTemplateType
    public var defaultPaperColor: PaperColor
    public var pages: [NotePage]
    public var pdfFileName: String?
    /// Set when the document is moved to Recently Deleted; nil for live documents.
    public var deletedDate: Date? = nil
    /// Whether the side note-taking margin is shown next to PDF pages (nil = default, shown).
    public var showsMargin: Bool? = nil

    public init(
        id: UUID = UUID(),
        title: String,
        folderId: UUID? = nil,
        type: DocumentType = .notebook,
        createdDate: Date = Date(),
        updatedDate: Date = Date(),
        tags: [String] = [],
        isFavorite: Bool = false,
        coverColorHex: String = "#4E2A84",
        defaultTemplate: PaperTemplateType = .ruled,
        defaultPaperColor: PaperColor = .ivory,
        pages: [NotePage] = [],
        pdfFileName: String? = nil
    ) {
        self.id = id
        self.title = title
        self.folderId = folderId
        self.type = type
        self.createdDate = createdDate
        self.updatedDate = updatedDate
        self.tags = tags
        self.isFavorite = isFavorite
        self.coverColorHex = coverColorHex
        self.defaultTemplate = defaultTemplate
        self.defaultPaperColor = defaultPaperColor
        self.pages = pages
        self.pdfFileName = pdfFileName
    }
    
    public var pageCount: Int {
        pages.count
    }

    public var isInTrash: Bool {
        deletedDate != nil
    }

    public var isMarginVisible: Bool {
        showsMargin ?? true
    }
}
