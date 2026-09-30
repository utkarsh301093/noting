import SwiftUI

/// Classical editorial sheet presenting file manager controls and document attributes:
/// Inline renaming, folder destination moving, duplication, PDF export, metadata, and quick switcher.
public struct FolioDocumentPropertiesSheet: View {
    let documentId: UUID
    @ObservedObject var store: DocumentStore
    let isDark: Bool
    let onClose: () -> Void
    let onOpenQuickSwitcher: () -> Void
    let onDocumentDeleted: () -> Void
    let onExportPDF: () -> Void
    
    @State private var editedTitle: String = ""
    @State private var showFolderPicker: Bool = false
    @State private var showDeleteConfirmation: Bool = false
    @State private var showDuplicateNotice: Bool = false
    
    private var doc: NoteDocument? {
        store.documents.first { $0.id == documentId }
    }
    
    private var currentFolderName: String {
        guard let doc = doc, let fid = doc.folderId else { return "Home" }
        return store.folder(for: fid)?.name ?? "Folder"
    }
    
    public init(
        documentId: UUID,
        store: DocumentStore,
        isDark: Bool,
        onClose: @escaping () -> Void,
        onOpenQuickSwitcher: @escaping () -> Void,
        onDocumentDeleted: @escaping () -> Void,
        onExportPDF: @escaping () -> Void
    ) {
        self.documentId = documentId
        self.store = store
        self.isDark = isDark
        self.onClose = onClose
        self.onOpenQuickSwitcher = onOpenQuickSwitcher
        self.onDocumentDeleted = onDocumentDeleted
        self.onExportPDF = onExportPDF
    }
    
    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let doc = doc {
                        documentNameSection(doc: doc)
                        locationSection(doc: doc)
                        attributesSection(doc: doc)
                        actionsSection(doc: doc)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            .background(FolioTheme.bg(isDark: isDark))
            .navigationTitle("File Manager")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        saveTitle()
                        onClose()
                    }
                    .foregroundColor(FolioTheme.accent(isDark: isDark))
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                if let doc = doc {
                    editedTitle = doc.title
                }
            }
            .sheet(isPresented: $showFolderPicker) {
                if let doc = doc {
                    FolderPickerSheet(
                        currentFolderId: doc.folderId,
                        store: store,
                        isDark: isDark
                    ) { targetFolderId in
                        store.moveDocument(id: doc.id, to: targetFolderId)
                        let generator = UIImpactFeedbackGenerator(style: .medium)
                        generator.impactOccurred()
                        showFolderPicker = false
                    }
                }
            }
            .alert("Delete \(doc?.type == .pdfDocument ? "PDF" : "Notebook")?", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    if let doc = doc {
                        store.deleteDocument(id: doc.id)
                        onClose()
                        onDocumentDeleted()
                    }
                }
            } message: {
                Text("“\(doc?.title ?? "This document")” will be moved to Recently Deleted. You can restore it from there for \(DocumentStore.trashRetentionDays) days.")
            }
            .overlay(alignment: .bottom) {
                if showDuplicateNotice {
                    Text("Notebook duplicated successfully")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.85))
                        .cornerRadius(20)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }
    
    private func saveTitle() {
        guard let doc = doc else { return }
        let trimmed = editedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != doc.title {
            store.renameDocument(id: doc.id, newTitle: trimmed)
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    // MARK: - Sections
    
    @ViewBuilder
    private func documentNameSection(doc: NoteDocument) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DOCUMENT NAME")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.0)
                .foregroundColor(FolioTheme.accent(isDark: isDark))
            
            HStack(spacing: 10) {
                Image(systemName: doc.type == .pdfDocument ? "doc.richtext" : "book.closed")
                    .font(.system(size: 18))
                    .foregroundColor(FolioTheme.accent(isDark: isDark))
                
                TextField("Notebook Name", text: $editedTitle)
                    .font(FolioTheme.serifHeading(size: 18, weight: .medium))
                    .foregroundColor(FolioTheme.text(isDark: isDark))
                    .onSubmit {
                        saveTitle()
                    }
                
                if editedTitle != doc.title && !editedTitle.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button {
                        saveTitle()
                    } label: {
                        Text("Save")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(FolioTheme.accent(isDark: isDark))
                            .cornerRadius(6)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(isDark ? Color(hex: "#242323") : Color.white)
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(FolioTheme.divider(isDark: isDark), lineWidth: 1))
        }
    }
    
    @ViewBuilder
    private func locationSection(doc: NoteDocument) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LOCATION & FOLDER")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.0)
                .foregroundColor(FolioTheme.accent(isDark: isDark))
            
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: doc.folderId == nil ? "house" : "folder")
                        .font(.system(size: 16))
                        .foregroundColor(FolioTheme.accent(isDark: isDark))
                    Text(currentFolderName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(FolioTheme.text(isDark: isDark))
                }
                
                Spacer()
                
                Button {
                    showFolderPicker = true
                } label: {
                    HStack(spacing: 4) {
                        Text("Move...")
                            .font(.system(size: 13, weight: .medium))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(FolioTheme.accent(isDark: isDark))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(FolioTheme.accent(isDark: isDark).opacity(0.12))
                    .cornerRadius(6)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(isDark ? Color(hex: "#242323") : Color.white)
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(FolioTheme.divider(isDark: isDark), lineWidth: 1))
        }
    }
    
    @ViewBuilder
    private func attributesSection(doc: NoteDocument) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("FILE ATTRIBUTES")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.0)
                .foregroundColor(FolioTheme.accent(isDark: isDark))
            
            VStack(spacing: 0) {
                Group {
                    AttributeRow(title: "Pages", value: "\(doc.pages.count) Pages", isDark: isDark)
                    Divider().background(FolioTheme.divider(isDark: isDark))
                    AttributeRow(title: "Format", value: doc.type == .pdfDocument ? "Annotated PDF" : "Folio Vector Notebook", isDark: isDark)
                    Divider().background(FolioTheme.divider(isDark: isDark))
                    AttributeRow(title: "Template", value: doc.defaultTemplate.displayName, isDark: isDark)
                    Divider().background(FolioTheme.divider(isDark: isDark))
                }
                Group {
                    AttributeRow(title: "Created", value: formatDate(doc.createdDate), isDark: isDark)
                    Divider().background(FolioTheme.divider(isDark: isDark))
                    AttributeRow(title: "Modified", value: formatDate(doc.updatedDate), isDark: isDark)
                    Divider().background(FolioTheme.divider(isDark: isDark))
                    AttributeRow(title: "Storage", value: "Offline iPad Storage (Documents)", isDark: isDark)
                }
            }
            .background(isDark ? Color(hex: "#242323") : Color.white)
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(FolioTheme.divider(isDark: isDark), lineWidth: 1))
        }
    }
    
    @ViewBuilder
    private func actionsSection(doc: NoteDocument) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ACTIONS")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.0)
                .foregroundColor(FolioTheme.accent(isDark: isDark))
            
            VStack(spacing: 2) {
                ActionRowButton(
                    icon: "plus.square.on.square",
                    title: doc.type == .pdfDocument ? "Duplicate PDF" : "Duplicate Notebook",
                    subtitle: "Create a complete copy with all notes",
                    isDestructive: false,
                    isDark: isDark
                ) {
                    store.duplicateDocument(id: doc.id)
                    let generator = UIImpactFeedbackGenerator(style: .medium)
                    generator.impactOccurred()
                    showDuplicateNotice = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        showDuplicateNotice = false
                    }
                }
                
                ActionRowButton(
                    icon: "sidebar.left",
                    title: "Browse Folders & Notes",
                    subtitle: "Open quick switcher slide-out panel",
                    isDestructive: false,
                    isDark: isDark
                ) {
                    onClose()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        onOpenQuickSwitcher()
                    }
                }
                
                ActionRowButton(
                    icon: "square.and.arrow.up",
                    title: "Export as PDF",
                    subtitle: "Share or save pages with your handwriting and margin notes",
                    isDestructive: false,
                    isDark: isDark
                ) {
                    onClose()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        onExportPDF()
                    }
                }
                
                ActionRowButton(
                    icon: "trash",
                    title: doc.type == .pdfDocument ? "Delete PDF" : "Delete Notebook",
                    subtitle: "Move this document to Recently Deleted",
                    isDestructive: true,
                    isDark: isDark
                ) {
                    showDeleteConfirmation = true
                }
            }
            .background(isDark ? Color(hex: "#242323") : Color.white)
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(FolioTheme.divider(isDark: isDark), lineWidth: 1))
        }
    }
}

// MARK: - Subviews

private struct AttributeRow: View {
    let title: String
    let value: String
    let isDark: Bool
    
    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(FolioTheme.textSecondary(isDark: isDark))
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(FolioTheme.text(isDark: isDark))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct ActionRowButton: View {
    let icon: String
    let title: String
    let subtitle: String
    let isDestructive: Bool
    let isDark: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(isDestructive ? Color(hex: "#B54D35") : FolioTheme.accent(isDark: isDark))
                    .frame(width: 24)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(isDestructive ? Color(hex: "#B54D35") : FolioTheme.text(isDark: isDark))
                    
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(FolioTheme.textSecondary(isDark: isDark))
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
                    .foregroundColor(FolioTheme.textSecondary(isDark: isDark).opacity(0.5))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Folder Picker Modal

public struct FolderPickerSheet: View {
    let currentFolderId: UUID?
    @ObservedObject var store: DocumentStore
    let isDark: Bool
    /// Folders that can't be chosen (e.g. a folder being moved and its own subfolders).
    var excludedFolderIds: Set<UUID> = []
    var title: String = "Move to Folder"
    let onSelect: (UUID?) -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    public var body: some View {
        NavigationStack {
            List {
                // Home Option
                Button {
                    onSelect(nil)
                } label: {
                    HStack {
                        Image(systemName: "house.fill")
                            .foregroundColor(FolioTheme.accent(isDark: isDark))
                        Text("Home (top level)")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(FolioTheme.text(isDark: isDark))
                        Spacer()
                        if currentFolderId == nil {
                            Image(systemName: "checkmark")
                                .foregroundColor(FolioTheme.accent(isDark: isDark))
                        }
                    }
                    .padding(.vertical, 4)
                }
                
                // All Folders, indented by nesting
                Section(header: Text("FOLDERS")) {
                    ForEach(store.folderTree()) { entry in
                        let isExcluded = excludedFolderIds.contains(entry.folder.id)
                        Button {
                            onSelect(entry.folder.id)
                        } label: {
                            HStack {
                                Image(systemName: "folder")
                                    .foregroundColor(FolioTheme.accent(isDark: isDark))
                                Text(entry.folder.name)
                                    .font(.system(size: 15))
                                    .foregroundColor(FolioTheme.text(isDark: isDark))
                                Spacer()
                                if currentFolderId == entry.folder.id {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(FolioTheme.accent(isDark: isDark))
                                }
                            }
                            .padding(.leading, CGFloat(entry.depth) * 18)
                            .padding(.vertical, 4)
                            .opacity(isExcluded ? 0.35 : 1)
                        }
                        .disabled(isExcluded)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(FolioTheme.accent(isDark: isDark))
                }
            }
        }
    }
}
