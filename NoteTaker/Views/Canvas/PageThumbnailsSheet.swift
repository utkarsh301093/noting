import SwiftUI

/// Grid of all pages: tap to jump to a page; menu to bookmark, duplicate or delete it.
public struct PageThumbnailsSheet: View {
    public let document: NoteDocument
    @ObservedObject public var store: DocumentStore
    /// The page currently in view, highlighted in the grid.
    public let currentPageId: UUID?
    /// Called with the tapped (or newly added) page's id so the editor can scroll to it.
    public let onSelectPage: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    
    /// Live copy from the store, so the grid reflects deletes/duplicates made from this sheet.
    private var liveDocument: NoteDocument {
        store.documents.first { $0.id == document.id } ?? document
    }
    
    let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 18)
    ]
    
    public init(
        document: NoteDocument,
        store: DocumentStore,
        currentPageId: UUID?,
        onSelectPage: @escaping (UUID) -> Void
    ) {
        self.document = document
        self.store = store
        self.currentPageId = currentPageId
        self.onSelectPage = onSelectPage
    }
    
    public var body: some View {
        let document = liveDocument
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(Array(document.pages.enumerated()), id: \.element.id) { index, page in
                        PageThumbnailCard(
                            document: document,
                            page: page,
                            pdfURL: document.pdfFileName.map { store.pdfURL(for: $0) },
                            pageNumber: index + 1,
                            isSelected: currentPageId == page.id,
                            canDelete: document.pages.count > 1,
                            onSelect: {
                                onSelectPage(page.id)
                                dismiss()
                            },
                            onDuplicate: {
                                store.duplicatePage(pageId: page.id, in: document.id)
                            },
                            onDelete: {
                                store.deletePage(pageId: page.id, from: document.id)
                            },
                            onToggleBookmark: {
                                store.toggleBookmark(pageId: page.id, in: document.id)
                            }
                        )
                    }
                }
                .padding(20)
            }
            .navigationTitle("Pages (\(document.pages.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        if let newPage = store.addPage(to: document.id) {
                            onSelectPage(newPage.id)
                            dismiss()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                            Text("Add Page")
                        }
                        .fontWeight(.semibold)
                        .foregroundColor(BrandTheme.brandPurple)
                    }
                }
            }
        }
    }
}

/// Single card in the page thumbnails grid
struct PageThumbnailCard: View {
    let document: NoteDocument
    let page: NotePage
    var pdfURL: URL? = nil
    let pageNumber: Int
    let isSelected: Bool
    var canDelete: Bool = true
    let onSelect: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void
    let onToggleBookmark: () -> Void
    
    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                // Page preview: the real PDF page, or the paper template
                Group {
                    if let pdfURL = pdfURL, let pdfIndex = page.pdfPageIndex {
                        PDFPageBackgroundView(pdfURL: pdfURL, pageIndex: pdfIndex)
                    } else {
                        PaperBackgroundView(templateType: page.templateType, paperColor: page.paperColor, contentScale: 0.2)
                    }
                }
                    .frame(height: 190)
                    .cornerRadius(8)
                    .shadow(color: Color.black.opacity(0.12), radius: 4, x: 0, y: 2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? BrandTheme.brandPurple : Color.gray.opacity(0.2), lineWidth: isSelected ? 3 : 1)
                    )
                
                // Bookmark Ribbon
                if page.isBookmarked {
                    Image(systemName: "bookmark.fill")
                        .foregroundColor(BrandTheme.brandGold)
                        .font(.system(size: 16))
                        .padding(8)
                }
            }
            
            // Page Number and Options
            HStack {
                Text("\(pageNumber)")
                    .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                    .foregroundColor(isSelected ? BrandTheme.brandPurple : .secondary)
                
                Spacer()
                
                Menu {
                    Button(action: onToggleBookmark) {
                        Label(page.isBookmarked ? "Remove Bookmark" : "Bookmark Page", systemImage: page.isBookmarked ? "bookmark.slash" : "bookmark")
                    }
                    Button(action: onDuplicate) {
                        Label("Duplicate Page", systemImage: "doc.on.doc")
                    }
                    Divider()
                    if canDelete {
                        Button(role: .destructive, action: onDelete) {
                            Label("Delete Page", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 4)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}
