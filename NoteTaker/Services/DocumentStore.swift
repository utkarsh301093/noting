import Foundation
import SwiftUI
import PencilKit
import PDFKit

/// A folder plus its nesting depth, for rendering indented folder lists.
public struct FolderTreeEntry: Identifiable {
    public let folder: Folder
    public let depth: Int
    public var id: UUID { folder.id }
}

/// Library data and on-device persistence: folders, documents, drawings and imported PDFs.
@MainActor
public final class DocumentStore: ObservableObject {
    public static let shared = DocumentStore()

    /// Documents in Recently Deleted are purged after this many days.
    public static let trashRetentionDays = 30

    @Published public var folders: [Folder] = []
    @Published public var documents: [NoteDocument] = []
    @Published public var searchQuery: String = ""
    /// Bumped when a page drawing is written by something other than that page's own canvas
    /// (e.g. the Zoom Window), so on-screen canvases know to reload it.
    @Published public private(set) var drawingRevisions: [UUID: Int] = [:]

    private let fileManager = FileManager.default
    private let appSupportURL: URL
    private let drawingsDirectoryURL: URL
    private let pdfsDirectoryURL: URL
    private let recordingsDirectoryURL: URL
    private let metadataURL: URL

    public init() {
        let paths = fileManager.urls(for: .documentDirectory, in: .userDomainMask)
        // Folder name can be overridden per build (NOTING_DATA_FOLDER in Config/Signing.xcconfig).
        let folderName = (Bundle.main.object(forInfoDictionaryKey: "NotingDataFolder") as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "NotingData"
        let root = paths.first!.appendingPathComponent(folderName, isDirectory: true)
        self.appSupportURL = root
        self.drawingsDirectoryURL = root.appendingPathComponent("Drawings", isDirectory: true)
        self.pdfsDirectoryURL = root.appendingPathComponent("PDFs", isDirectory: true)
        self.recordingsDirectoryURL = root.appendingPathComponent("Recordings", isDirectory: true)
        self.metadataURL = root.appendingPathComponent("library_v1.json")

        setupDirectories()
        loadLibrary()
    }

    // MARK: - Setup & Directory Management

    /// Files are written with complete data protection: encrypted whenever the iPad is locked.
    private static let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtection]

    private func setupDirectories() {
        for dir in [appSupportURL, drawingsDirectoryURL, pdfsDirectoryURL] {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            // New files (e.g. copies) inherit the directory's protection class.
            try? fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: dir.path)
        }
    }

    // MARK: - Persistence

    private struct LibraryContainer: Codable {
        var folders: [Folder]
        var documents: [NoteDocument]
    }

    public func saveLibrary() {
        let container = LibraryContainer(folders: folders, documents: documents)
        do {
            let data = try JSONEncoder().encode(container)
            try data.write(to: metadataURL, options: Self.writeOptions)
        } catch {
            print("Failed to save library metadata: \(error)")
        }
    }

    private func loadLibrary() {
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            // First launch
            createStarterContent()
            saveLibrary()
            return
        }

        guard let data = try? Data(contentsOf: metadataURL),
              let container = try? JSONDecoder().decode(LibraryContainer.self, from: data) else {
            // Never silently overwrite a library we couldn't read — keep a copy before starting fresh.
            let stamp = Int(Date().timeIntervalSince1970)
            let backupURL = appSupportURL.appendingPathComponent("library_v1.unreadable-\(stamp).json")
            try? fileManager.copyItem(at: metadataURL, to: backupURL)
            print("Library metadata unreadable; backed up to \(backupURL.lastPathComponent)")
            createStarterContent()
            saveLibrary()
            return
        }

        folders = container.folders
        documents = container.documents

        purgeExpiredTrash()
        saveLibrary()
    }

    // MARK: - First Launch

    /// A fresh install starts with one folder holding one empty notebook.
    private func createStarterContent() {
        let folder = Folder(name: "My Notes", colorHex: "#b68235", iconName: "folder.fill")
        folders.append(folder)
        var notebook = NoteDocument(
            title: "My First Notebook",
            folderId: folder.id,
            type: .notebook,
            coverColorHex: "#b68235",
            defaultTemplate: .ruled,
            defaultPaperColor: .ivory
        )
        notebook.pages = [NotePage(documentId: notebook.id, pageIndex: 0, templateType: .ruled, paperColor: .ivory)]
        documents.append(notebook)
    }

    // MARK: - Folder Queries

    public func subfolders(of parentId: UUID?) -> [Folder] {
        folders.filter { $0.parentId == parentId }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func folder(for id: UUID?) -> Folder? {
        guard let id = id else { return nil }
        return folders.first { $0.id == id }
    }

    public func breadcrumbPath(for folderId: UUID?) -> [Folder] {
        guard let folderId = folderId else { return [] }
        var path: [Folder] = []
        var visited: Set<UUID> = []
        var current: Folder? = folder(for: folderId)
        while let f = current, !visited.contains(f.id) {
            visited.insert(f.id)
            path.insert(f, at: 0)
            current = folder(for: f.parentId)
        }
        return path
    }

    /// The folder and every folder nested anywhere beneath it.
    public func descendantFolderIds(of id: UUID) -> Set<UUID> {
        var result: Set<UUID> = [id]
        var frontier: [UUID] = [id]
        while let next = frontier.popLast() {
            for child in folders where child.parentId == next && !result.contains(child.id) {
                result.insert(child.id)
                frontier.append(child.id)
            }
        }
        return result
    }

    /// All folders in display order (depth-first, alphabetical), with nesting depth.
    public func folderTree() -> [FolderTreeEntry] {
        var result: [FolderTreeEntry] = []
        func visit(_ parentId: UUID?, depth: Int) {
            for f in subfolders(of: parentId) {
                result.append(FolderTreeEntry(folder: f, depth: depth))
                visit(f.id, depth: depth + 1)
            }
        }
        visit(nil, depth: 0)
        return result
    }

    /// Number of direct children (subfolders + live documents) in a folder.
    public func itemCount(inFolder id: UUID) -> Int {
        subfolders(of: id).count + documents(in: id).count
    }

    /// Counts of everything that deleting this folder would remove.
    public func deletionSummary(forFolder id: UUID) -> (subfolders: Int, documents: Int) {
        let ids = descendantFolderIds(of: id)
        let docCount = activeDocuments.filter { $0.folderId.map(ids.contains) ?? false }.count
        return (ids.count - 1, docCount)
    }

    // MARK: - Folder Operations

    public func createFolder(
        name: String,
        parentId: UUID? = nil,
        colorHex: String = "#4E2A84",
        iconName: String = "folder.fill"
    ) -> Folder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let newFolder = Folder(
            name: trimmed.isEmpty ? "Untitled Folder" : trimmed,
            parentId: parentId,
            colorHex: colorHex,
            iconName: iconName
        )
        folders.append(newFolder)
        saveLibrary()
        return newFolder
    }

    public func renameFolder(id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[idx].name = trimmed
        folders[idx].updatedDate = Date()
        saveLibrary()
    }

    /// Moves a folder under a new parent (nil = top level). Refuses moves into itself or its own subfolders.
    @discardableResult
    public func moveFolder(id: UUID, to newParentId: UUID?) -> Bool {
        if let target = newParentId, descendantFolderIds(of: id).contains(target) {
            return false
        }
        guard let idx = folders.firstIndex(where: { $0.id == id }) else { return false }
        folders[idx].parentId = newParentId
        folders[idx].updatedDate = Date()
        saveLibrary()
        return true
    }

    /// Deletes a folder and all of its subfolders. Documents inside are moved to Recently Deleted.
    public func deleteFolder(id: UUID) {
        let toDelete = descendantFolderIds(of: id)
        let now = Date()
        for idx in documents.indices where documents[idx].deletedDate == nil {
            if let fid = documents[idx].folderId, toDelete.contains(fid) {
                documents[idx].deletedDate = now
            }
        }

        folders.removeAll { toDelete.contains($0.id) }
        saveLibrary()
    }

    // MARK: - Document Queries

    /// Documents that are not in Recently Deleted.
    public var activeDocuments: [NoteDocument] {
        documents.filter { !$0.isInTrash }
    }

    public var trashedDocuments: [NoteDocument] {
        documents.filter { $0.isInTrash }
            .sorted { ($0.deletedDate ?? .distantPast) > ($1.deletedDate ?? .distantPast) }
    }

    public func documents(in folderId: UUID?) -> [NoteDocument] {
        activeDocuments
            .filter { $0.folderId == folderId }
            .sorted { $0.updatedDate > $1.updatedDate }
    }

    public func searchDocuments(matching query: String) -> [NoteDocument] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return activeDocuments.filter {
            $0.title.localizedCaseInsensitiveContains(q) ||
            $0.tags.contains { $0.localizedCaseInsensitiveContains(q) }
        }
        .sorted { $0.updatedDate > $1.updatedDate }
    }

    public func favoriteDocuments() -> [NoteDocument] {
        activeDocuments.filter { $0.isFavorite }.sorted { $0.updatedDate > $1.updatedDate }
    }

    public func recentDocuments(limit: Int = 10) -> [NoteDocument] {
        Array(activeDocuments.sorted { $0.updatedDate > $1.updatedDate }.prefix(limit))
    }

    // MARK: - Document Operations

    public func createNotebook(
        title: String,
        folderId: UUID? = nil,
        template: PaperTemplateType = .ruled,
        paperColor: PaperColor = .ivory,
        coverColorHex: String = "#4E2A84"
    ) -> NoteDocument {
        var doc = NoteDocument(
            title: title.isEmpty ? "Untitled Notebook" : title,
            folderId: folderId,
            type: .notebook,
            coverColorHex: coverColorHex,
            defaultTemplate: template,
            defaultPaperColor: paperColor
        )
        let firstPage = NotePage(
            documentId: doc.id,
            pageIndex: 0,
            templateType: template,
            paperColor: paperColor
        )
        doc.pages = [firstPage]
        documents.append(doc)
        saveLibrary()
        return doc
    }

    /// Moves a document to Recently Deleted. Use `permanentlyDeleteDocument` to remove it for good.
    public func deleteDocument(id: UUID) {
        guard let idx = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[idx].deletedDate = Date()
        saveLibrary()
    }

    public func restoreDocument(id: UUID) {
        guard let idx = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[idx].deletedDate = nil
        // If its folder was deleted in the meantime, restore to Home.
        if let fid = documents[idx].folderId, folder(for: fid) == nil {
            documents[idx].folderId = nil
        }
        saveLibrary()
    }

    public func permanentlyDeleteDocument(id: UUID) {
        guard let doc = documents.first(where: { $0.id == id }) else { return }
        removeFiles(for: doc)
        documents.removeAll { $0.id == id }
        saveLibrary()
    }

    public func emptyTrash() {
        for doc in documents where doc.isInTrash {
            removeFiles(for: doc)
        }
        documents.removeAll { $0.isInTrash }
        saveLibrary()
    }

    private func purgeExpiredTrash() {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -Self.trashRetentionDays, to: Date()) else { return }
        let expired = documents.filter { ($0.deletedDate ?? .distantFuture) < cutoff }
        for doc in expired {
            removeFiles(for: doc)
        }
        let expiredIds = Set(expired.map { $0.id })
        documents.removeAll { expiredIds.contains($0.id) }
    }

    /// Removes a document's drawings, PDF, and lecture recordings from disk.
    private func removeFiles(for doc: NoteDocument) {
        for page in doc.pages {
            try? fileManager.removeItem(at: drawingsDirectoryURL.appendingPathComponent(page.drawingDataFileName))
            try? fileManager.removeItem(at: drawingsDirectoryURL.appendingPathComponent(page.marginDrawingFileName))
        }
        if let pdfName = doc.pdfFileName {
            try? fileManager.removeItem(at: pdfURL(for: pdfName))
        }
        if let recordings = try? fileManager.contentsOfDirectory(atPath: recordingsDirectoryURL.path) {
            for name in recordings where name.hasPrefix(doc.id.uuidString) {
                try? fileManager.removeItem(at: recordingsDirectoryURL.appendingPathComponent(name))
            }
        }
    }

    public func duplicateDocument(id: UUID) {
        guard let doc = documents.first(where: { $0.id == id }) else { return }
        let newDocId = UUID()
        var newDoc = NoteDocument(
            id: newDocId,
            title: "\(doc.title) (Copy)",
            folderId: doc.folderId,
            type: doc.type,
            createdDate: Date(),
            updatedDate: Date(),
            tags: doc.tags,
            isFavorite: false,
            coverColorHex: doc.coverColorHex,
            defaultTemplate: doc.defaultTemplate,
            defaultPaperColor: doc.defaultPaperColor,
            pages: [],
            pdfFileName: nil
        )
        newDoc.showsMargin = doc.showsMargin

        // Copy PDF if needed
        if let oldPdfName = doc.pdfFileName {
            let ext = (oldPdfName as NSString).pathExtension
            let newPdfName = "\(newDocId.uuidString).\(ext)"
            let oldURL = pdfURL(for: oldPdfName)
            let newURL = pdfsDirectoryURL.appendingPathComponent(newPdfName)
            try? fileManager.copyItem(at: oldURL, to: newURL)
            newDoc.pdfFileName = newPdfName
        }

        // Duplicate pages & drawings
        for page in doc.pages {
            let newPage = NotePage(
                documentId: newDocId,
                pageIndex: page.pageIndex,
                templateType: page.templateType,
                paperColor: page.paperColor,
                pdfPageIndex: page.pdfPageIndex,
                isBookmarked: page.isBookmarked
            )
            copyDrawingFiles(from: page, to: newPage)
            newDoc.pages.append(newPage)
        }

        documents.append(newDoc)
        saveLibrary()
    }

    private func copyDrawingFiles(from source: NotePage, to destination: NotePage) {
        let pairs = [
            (source.drawingDataFileName, destination.drawingDataFileName),
            (source.marginDrawingFileName, destination.marginDrawingFileName)
        ]
        for (from, to) in pairs {
            let fromURL = drawingsDirectoryURL.appendingPathComponent(from)
            guard fileManager.fileExists(atPath: fromURL.path) else { continue }
            try? fileManager.copyItem(at: fromURL, to: drawingsDirectoryURL.appendingPathComponent(to))
        }
    }

    public func toggleFavorite(documentId: UUID) {
        if let idx = documents.firstIndex(where: { $0.id == documentId }) {
            documents[idx].isFavorite.toggle()
            saveLibrary()
        }
    }

    public func moveDocument(id: UUID, to folderId: UUID?) {
        if let idx = documents.firstIndex(where: { $0.id == id }) {
            documents[idx].folderId = folderId
            documents[idx].updatedDate = Date()
            saveLibrary()
        }
    }

    public func renameDocument(id: UUID, newTitle: String) {
        if let idx = documents.firstIndex(where: { $0.id == id }) {
            let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            documents[idx].title = trimmed.isEmpty ? "Untitled Notebook" : trimmed
            documents[idx].updatedDate = Date()
            saveLibrary()
        }
    }

    public func setMarginVisible(_ visible: Bool, for documentId: UUID) {
        guard let idx = documents.firstIndex(where: { $0.id == documentId }) else { return }
        documents[idx].showsMargin = visible
        saveLibrary()
    }

    // MARK: - Page Operations

    public func addPage(
        to documentId: UUID,
        templateType: PaperTemplateType? = nil,
        paperColor: PaperColor? = nil,
        at index: Int? = nil
    ) -> NotePage? {
        guard let docIdx = documents.firstIndex(where: { $0.id == documentId }) else { return nil }
        var doc = documents[docIdx]

        let insertIndex = min(max(0, index ?? doc.pages.count), doc.pages.count)
        let template = templateType ?? doc.defaultTemplate
        let color = paperColor ?? doc.defaultPaperColor

        let newPage = NotePage(
            documentId: documentId,
            pageIndex: insertIndex,
            templateType: template,
            paperColor: color
        )

        doc.pages.insert(newPage, at: insertIndex)
        for i in 0..<doc.pages.count {
            doc.pages[i].pageIndex = i
        }
        doc.updatedDate = Date()
        documents[docIdx] = doc
        saveLibrary()
        return newPage
    }

    public func deletePage(pageId: UUID, from documentId: UUID) {
        guard let docIdx = documents.firstIndex(where: { $0.id == documentId }) else { return }
        var doc = documents[docIdx]
        guard doc.pages.count > 1 else { return } // Keep at least one page

        if let pageIdx = doc.pages.firstIndex(where: { $0.id == pageId }) {
            let page = doc.pages.remove(at: pageIdx)
            try? fileManager.removeItem(at: drawingsDirectoryURL.appendingPathComponent(page.drawingDataFileName))
            try? fileManager.removeItem(at: drawingsDirectoryURL.appendingPathComponent(page.marginDrawingFileName))

            for i in 0..<doc.pages.count {
                doc.pages[i].pageIndex = i
            }
            doc.updatedDate = Date()
            documents[docIdx] = doc
            saveLibrary()
        }
    }

    public func duplicatePage(pageId: UUID, in documentId: UUID) {
        guard let docIdx = documents.firstIndex(where: { $0.id == documentId }),
              let pageIdx = documents[docIdx].pages.firstIndex(where: { $0.id == pageId }) else { return }

        let originalPage = documents[docIdx].pages[pageIdx]
        let newPage = NotePage(
            documentId: documentId,
            pageIndex: pageIdx + 1,
            templateType: originalPage.templateType,
            paperColor: originalPage.paperColor,
            pdfPageIndex: originalPage.pdfPageIndex,
            isBookmarked: false
        )
        copyDrawingFiles(from: originalPage, to: newPage)

        documents[docIdx].pages.insert(newPage, at: pageIdx + 1)
        for i in 0..<documents[docIdx].pages.count {
            documents[docIdx].pages[i].pageIndex = i
        }
        documents[docIdx].updatedDate = Date()
        saveLibrary()
    }

    public func toggleBookmark(pageId: UUID, in documentId: UUID) {
        guard let docIdx = documents.firstIndex(where: { $0.id == documentId }),
              let pageIdx = documents[docIdx].pages.firstIndex(where: { $0.id == pageId }) else { return }
        documents[docIdx].pages[pageIdx].isBookmarked.toggle()
        saveLibrary()
    }

    public func updatePagePaper(pageId: UUID, in documentId: UUID, template: PaperTemplateType? = nil, color: PaperColor? = nil) {
        guard let docIdx = documents.firstIndex(where: { $0.id == documentId }),
              let pageIdx = documents[docIdx].pages.firstIndex(where: { $0.id == pageId }) else { return }
        if let template = template {
            documents[docIdx].pages[pageIdx].templateType = template
        }
        if let color = color {
            documents[docIdx].pages[pageIdx].paperColor = color
        }
        saveLibrary()
    }

    /// Applies paper settings to every non-PDF page and makes them the default for new pages.
    public func applyPaperToAllPages(in documentId: UUID, template: PaperTemplateType, color: PaperColor) {
        guard let docIdx = documents.firstIndex(where: { $0.id == documentId }) else { return }
        for i in documents[docIdx].pages.indices where documents[docIdx].pages[i].pdfPageIndex == nil {
            documents[docIdx].pages[i].templateType = template
            documents[docIdx].pages[i].paperColor = color
        }
        documents[docIdx].defaultTemplate = template
        documents[docIdx].defaultPaperColor = color
        saveLibrary()
    }

    // MARK: - Drawing Data Management

    private func drawingURL(for fileName: String) -> URL {
        drawingsDirectoryURL.appendingPathComponent(fileName)
    }

    public func loadDrawing(for page: NotePage) -> PKDrawing {
        loadDrawing(fileName: page.drawingDataFileName)
    }

    /// Saves a page drawing. Pass `notifyCanvases: true` when the write didn't come from the
    /// page's own canvas, so any on-screen canvas for that page reloads it.
    public func saveDrawing(_ drawing: PKDrawing, for page: NotePage, notifyCanvases: Bool = false) {
        saveDrawing(drawing, fileName: page.drawingDataFileName)
        touchDocument(page.documentId)
        if notifyCanvases {
            drawingRevisions[page.id, default: 0] += 1
        }
    }

    public func drawingRevision(for pageId: UUID) -> Int {
        drawingRevisions[pageId] ?? 0
    }

    public func loadMarginDrawing(for page: NotePage) -> PKDrawing {
        loadDrawing(fileName: page.marginDrawingFileName)
    }

    public func saveMarginDrawing(_ drawing: PKDrawing, for page: NotePage) {
        saveDrawing(drawing, fileName: page.marginDrawingFileName)
        touchDocument(page.documentId)
    }

    private func loadDrawing(fileName: String) -> PKDrawing {
        let url = drawingURL(for: fileName)
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let drawing = try? PKDrawing(data: data) else {
            return PKDrawing()
        }
        return drawing
    }

    private func saveDrawing(_ drawing: PKDrawing, fileName: String) {
        let url = drawingURL(for: fileName)
        let data = drawing.dataRepresentation()
        do {
            try data.write(to: url, options: Self.writeOptions)
        } catch {
            print("Failed to save drawing \(fileName): \(error)")
        }
    }

    /// Marks a document as modified so it sorts into Recents. Debounced, since this fires on
    /// every stroke and publishing a store change per stroke would re-render every page.
    private var pendingTouch: DispatchWorkItem?

    private func touchDocument(_ documentId: UUID) {
        pendingTouch?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self = self,
                      let idx = self.documents.firstIndex(where: { $0.id == documentId }) else { return }
                self.documents[idx].updatedDate = Date()
                self.saveLibrary()
            }
        }
        pendingTouch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    // MARK: - PDF File Management

    /// File names come from the library file, so only ever use the last path component.
    public func pdfURL(for fileName: String) -> URL {
        pdfsDirectoryURL.appendingPathComponent((fileName as NSString).lastPathComponent)
    }

    public func importPDF(from sourceURL: URL, into folderId: UUID?) throws -> NoteDocument {
        let shouldStopAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if shouldStopAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        guard let pdfDoc = PDFDocument(url: sourceURL) else {
            throw NSError(domain: "DocumentStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "This file isn't a readable PDF."])
        }
        if pdfDoc.isLocked {
            throw NSError(domain: "DocumentStore", code: 2, userInfo: [NSLocalizedDescriptionKey: "This PDF is password-protected. Unlock it in Files or Preview and import it again."])
        }
        guard pdfDoc.pageCount > 0 else {
            throw NSError(domain: "DocumentStore", code: 3, userInfo: [NSLocalizedDescriptionKey: "This PDF has no pages."])
        }

        let newDocId = UUID()
        let pdfFileName = "\(newDocId.uuidString).pdf"
        let destURL = pdfsDirectoryURL.appendingPathComponent(pdfFileName)

        let pdfData = try Data(contentsOf: sourceURL)
        try pdfData.write(to: destURL, options: Self.writeOptions)

        let title = sourceURL.deletingPathExtension().lastPathComponent
        var doc = NoteDocument(
            id: newDocId,
            title: title.isEmpty ? "Imported PDF" : title,
            folderId: folderId,
            type: .pdfDocument,
            tags: ["PDF", "Imported"],
            coverColorHex: "#235C97",
            defaultTemplate: .blank,
            defaultPaperColor: .white,
            pdfFileName: pdfFileName
        )

        for i in 0..<pdfDoc.pageCount {
            doc.pages.append(NotePage(
                documentId: newDocId,
                pageIndex: i,
                templateType: .blank,
                paperColor: .white,
                pdfPageIndex: i
            ))
        }

        documents.append(doc)
        saveLibrary()
        return doc
    }
}
