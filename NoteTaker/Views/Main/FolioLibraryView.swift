import SwiftUI
import UniformTypeIdentifiers

/// Folio Library Screen — editorial file browser for folders, notebooks and PDFs.
///
/// File management:
/// - Folders (sidebar rows and folder cards): long-press for Open / New Subfolder / Rename / Move / Delete.
/// - Documents: long-press for Open / Rename / Move / Duplicate / Favorite / Delete, or use Select for bulk actions.
/// - Deleted documents go to Recently Deleted and can be restored for `DocumentStore.trashRetentionDays` days.
public struct FolioLibraryView: View {
    @ObservedObject public var store = DocumentStore.shared
    @ObservedObject public var theme = ThemeManager.shared
    @Binding public var activeDocumentId: UUID?

    // Navigation & display
    @State private var sidebarSelection: SidebarSelection = .home
    @State private var sortOrder: LibrarySortOrder = .lastModified

    // Creation
    @State private var showNewNotebookSheet: Bool = false
    @State private var newFolderRequest: NewFolderRequest? = nil
    @State private var showPDFImporter: Bool = false

    // Selection mode
    @State private var isSelectMode: Bool = false
    @State private var selectedDocIds: Set<UUID> = []

    // File management dialogs
    @State private var renameTarget: RenameTarget? = nil
    @State private var renameText: String = ""
    @State private var moveTarget: MoveTarget? = nil
    @State private var folderPendingDelete: Folder? = nil
    @State private var docsPendingPermanentDelete: [UUID]? = nil
    @State private var showEmptyTrashConfirm: Bool = false
    @State private var importErrorMessage: String? = nil

    private var isDark: Bool { theme.isDarkMode }

    // MARK: - Navigation Resolution

    private var isSearching: Bool {
        !store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isTrashView: Bool {
        sidebarSelection == .trash && !isSearching
    }

    /// Views where the "folders" row, blank-notebook tile and New menu apply.
    private var isBrowsingFolder: Bool {
        guard !isSearching else { return false }
        switch sidebarSelection {
        case .home, .folder: return true
        default: return false
        }
    }

    private var currentFolderId: UUID? {
        if case .folder(let id) = sidebarSelection {
            return id
        }
        return nil
    }

    private var currentFolder: Folder? {
        store.folder(for: currentFolderId)
    }

    private var parentFolder: Folder? {
        guard let current = currentFolder, let parentId = current.parentId else { return nil }
        return store.folder(for: parentId)
    }

    private var currentSubfolders: [Folder] {
        if isSearching {
            let q = store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            return store.folders
                .filter { $0.name.localizedCaseInsensitiveContains(q) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        guard isBrowsingFolder else { return [] }
        return store.subfolders(of: currentFolderId)
    }

    private var currentDocuments: [NoteDocument] {
        if isSearching {
            return sorted(store.searchDocuments(matching: store.searchQuery))
        }
        switch sidebarSelection {
        case .home:
            return sorted(store.documents(in: nil))
        case .recent:
            return store.recentDocuments(limit: 30)
        case .favorites:
            return sorted(store.favoriteDocuments())
        case .trash:
            return store.trashedDocuments
        case .folder(let id):
            return sorted(store.documents(in: id))
        }
    }

    private func sorted(_ docs: [NoteDocument]) -> [NoteDocument] {
        switch sortOrder {
        case .lastModified:
            return docs.sorted { $0.updatedDate > $1.updatedDate }
        case .title:
            return docs.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .dateCreated:
            return docs.sorted { $0.createdDate > $1.createdDate }
        }
    }

    private var displayHeaderTitle: String {
        if isSearching { return "Search" }
        switch sidebarSelection {
        case .home: return "Home"
        case .recent: return "Recents"
        case .favorites: return "Favorites"
        case .trash: return "Recently Deleted"
        case .folder(let id): return store.folder(for: id)?.name ?? "Folder"
        }
    }

    private var documentsSectionTitle: String {
        if isSearching { return "DOCUMENTS" }
        switch sidebarSelection {
        case .recent: return "RECENT DOCUMENTS"
        case .favorites: return "FAVORITE DOCUMENTS"
        case .trash: return "DELETED DOCUMENTS"
        default: return "NOTEBOOKS & DOCUMENTS"
        }
    }

    private var emptyMessage: String {
        if isSearching { return "No notebooks or PDFs match “\(store.searchQuery)”" }
        switch sidebarSelection {
        case .recent: return "No recent notes"
        case .favorites: return "No favorites yet — long-press a document and choose Favorite"
        case .trash: return "Recently Deleted is empty"
        default: return "No notebooks here yet"
        }
    }

    private var folderActions: FolderActions {
        FolderActions(
            open: { folder in navigateToFolder(id: folder.id) },
            newSubfolder: { folder in newFolderRequest = NewFolderRequest(parentId: folder.id) },
            rename: { folder in
                renameText = folder.name
                renameTarget = .folder(folder)
            },
            move: { folder in moveTarget = .folder(folder) },
            delete: { folder in folderPendingDelete = folder }
        )
    }

    public init(activeDocumentId: Binding<UUID?>) {
        self._activeDocumentId = activeDocumentId
    }

    public var body: some View {
        HStack(spacing: 0) {
            sidebar
            mainPane
        }
        .onChange(of: sidebarSelection) {
            exitSelectMode()
        }
        .onChange(of: store.folders) {
            // If the folder being viewed disappeared (deleted elsewhere), fall back to Home.
            if let id = currentFolderId, store.folder(for: id) == nil {
                sidebarSelection = .home
            }
        }
        .sheet(isPresented: $showNewNotebookSheet) {
            NewNotebookSheet(store: store, defaultFolderId: currentFolderId) { created in
                activeDocumentId = created.id
            }
        }
        .sheet(item: $newFolderRequest) { request in
            NewFolderSheet(store: store, defaultParentId: request.parentId)
        }
        .sheet(item: $moveTarget) { target in
            moveSheet(for: target)
        }
        .fileImporter(
            isPresented: $showPDFImporter,
            allowedContentTypes: [UTType.pdf],
            allowsMultipleSelection: true
        ) { result in
            handleImport(result)
        }
        .alert(renameTarget?.alertTitle ?? "Rename", isPresented: isPresentedBinding($renameTarget)) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { commitRename() }
        }
        .alert(
            "Delete “\(folderPendingDelete?.name ?? "folder")”?",
            isPresented: isPresentedBinding($folderPendingDelete),
            presenting: folderPendingDelete
        ) { folder in
            Button("Delete Folder", role: .destructive) { deleteFolder(folder) }
            Button("Cancel", role: .cancel) {}
        } message: { folder in
            Text(folderDeletionMessage(folder))
        }
        .alert(
            "Delete permanently?",
            isPresented: isPresentedBinding($docsPendingPermanentDelete),
            presenting: docsPendingPermanentDelete
        ) { ids in
            Button("Delete", role: .destructive) {
                ids.forEach { store.permanentlyDeleteDocument(id: $0) }
                exitSelectMode()
            }
            Button("Cancel", role: .cancel) {}
        } message: { ids in
            Text(ids.count == 1 ? "This document and all its notes will be erased. This can't be undone." : "These \(ids.count) documents and all their notes will be erased. This can't be undone.")
        }
        .alert("Empty Recently Deleted?", isPresented: $showEmptyTrashConfirm) {
            Button("Delete All", role: .destructive) { store.emptyTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All \(store.trashedDocuments.count) documents will be erased permanently. This can't be undone.")
        }
        .alert("Couldn't import PDF", isPresented: isPresentedBinding($importErrorMessage)) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importErrorMessage ?? "")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header: Time & Library Title
            VStack(alignment: .leading, spacing: 4) {
                Text(formattedCurrentTime())
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(FolioTheme.textSecondary(isDark: isDark))
                    .padding(.top, 4)

                Text("Library")
                    .font(FolioTheme.serifHeading(size: 34, weight: .regular))
                    .foregroundColor(FolioTheme.text(isDark: isDark))
            }
            .padding(.horizontal, 16)

            // Search Input
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundColor(FolioTheme.textSecondary(isDark: isDark))
                TextField("Search titles, tags and folders", text: $store.searchQuery)
                    .font(.system(size: 13))
                    .foregroundColor(FolioTheme.text(isDark: isDark))
                    .autocorrectionDisabled()
                if isSearching {
                    Button {
                        store.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(FolioTheme.textSecondary(isDark: isDark))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isDark ? Color(hex: "#2c2b2b") : Color.white)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(FolioTheme.divider(isDark: isDark), lineWidth: 1)
            )
            .padding(.horizontal, 16)

            // Quick Access Rows
            VStack(spacing: 2) {
                SidebarQuickRow(
                    icon: "house",
                    title: "Home",
                    count: store.subfolders(of: nil).count + store.documents(in: nil).count,
                    isSelected: sidebarSelection == .home && !isSearching,
                    isDark: isDark
                ) {
                    selectSidebar(.home)
                }

                SidebarQuickRow(
                    icon: "clock",
                    title: "Recents",
                    count: store.recentDocuments(limit: 30).count,
                    isSelected: sidebarSelection == .recent && !isSearching,
                    isDark: isDark
                ) {
                    selectSidebar(.recent)
                }

                SidebarQuickRow(
                    icon: "star",
                    title: "Favorites",
                    count: store.favoriteDocuments().count,
                    isSelected: sidebarSelection == .favorites && !isSearching,
                    isDark: isDark
                ) {
                    selectSidebar(.favorites)
                }
            }
            .padding(.horizontal, 10)

            // FOLDERS Section Header
            HStack {
                Text("FOLDERS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundColor(FolioTheme.accent(isDark: isDark))
                Spacer()
                Button {
                    newFolderRequest = NewFolderRequest(parentId: nil)
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(FolioTheme.accent(isDark: isDark))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel("New folder")
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)

            // Hierarchical Folder Tree in Sidebar
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    let rootFolders = store.subfolders(of: nil)
                    if rootFolders.isEmpty {
                        Text("No folders yet. Tap + to create one.")
                            .font(.system(size: 12))
                            .foregroundColor(FolioTheme.textSecondary(isDark: isDark))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                    ForEach(rootFolders) { folder in
                        FolioFolderTreeRow(
                            folder: folder,
                            store: store,
                            selection: $sidebarSelection,
                            level: 0,
                            isDark: isDark,
                            actions: folderActions
                        )
                    }

                    Text("Long-press a folder to rename, move or delete it.")
                        .font(.system(size: 11))
                        .foregroundColor(FolioTheme.textSecondary(isDark: isDark).opacity(0.8))
                        .padding(.horizontal, 8)
                        .padding(.top, 10)
                }
                .padding(.horizontal, 10)
            }

            // Bottom: Recently Deleted & Theme Switcher
            VStack(spacing: 6) {
                Divider().background(FolioTheme.divider(isDark: isDark))

                SidebarQuickRow(
                    icon: "trash",
                    title: "Recently Deleted",
                    count: store.trashedDocuments.count,
                    isSelected: sidebarSelection == .trash && !isSearching,
                    isDark: isDark
                ) {
                    selectSidebar(.trash)
                }
                .padding(.horizontal, 10)

                // Light / Dark Mode Switcher Capsule
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: isDark ? "moon.stars.fill" : "sun.max.fill")
                            .foregroundColor(FolioTheme.accent(isDark: isDark))
                            .font(.system(size: 13))
                        Text(isDark ? "Classical Dark" : "Classical Light")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(FolioTheme.text(isDark: isDark))
                    }
                    Spacer()
                    Toggle("", isOn: $theme.isDarkMode)
                        .labelsHidden()
                        .scaleEffect(0.8)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isDark ? Color(hex: "#222121") : Color(hex: "#eae7e7"))
                .cornerRadius(8)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
        .frame(width: 300)
        .background(FolioTheme.surface(isDark: isDark))
        .overlay(
            Rectangle()
                .fill(FolioTheme.divider(isDark: isDark))
                .frame(width: 1),
            alignment: .trailing
        )
    }

    // MARK: - Main Browsing Pane

    private var mainPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            topActionBar
                .padding(.horizontal, 40)
                .padding(.top, 24)
                .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(displayHeaderTitle)
                            .font(FolioTheme.serifHeading(size: 40, weight: .regular))
                            .foregroundColor(FolioTheme.text(isDark: isDark))

                        if isTrashView {
                            Text("Documents are erased permanently after \(DocumentStore.trashRetentionDays) days. Long-press to restore.")
                                .font(.system(size: 13))
                                .foregroundColor(FolioTheme.textSecondary(isDark: isDark))
                        } else if let folderId = currentFolderId, !isSearching {
                            breadcrumbs(for: folderId)
                        }
                    }
                    .padding(.top, 4)

                    // SECTION 1: Folders
                    if !currentSubfolders.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("FOLDERS")
                                .font(.system(size: 11, weight: .semibold))
                                .tracking(1.0)
                                .foregroundColor(FolioTheme.textSecondary(isDark: isDark))

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 16) {
                                    ForEach(currentSubfolders) { sub in
                                        FolioFolderCard(folder: sub, store: store, isDark: isDark) {
                                            withAnimation(.spring(response: 0.25)) {
                                                navigateToFolder(id: sub.id)
                                            }
                                        }
                                        .folderContextMenu(sub, actions: folderActions)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }

                    // SECTION 2: Notebooks & Documents Grid (3:4 aspect tiles)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(documentsSectionTitle)
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(1.0)
                            .foregroundColor(FolioTheme.textSecondary(isDark: isDark))

                        if currentDocuments.isEmpty && !isBrowsingFolder {
                            emptyState
                        } else {
                            documentGrid
                        }
                    }
                }
                .padding(.horizontal, 40)
                .padding(.bottom, isSelectMode ? 120 : 60)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FolioTheme.bg(isDark: isDark))
        .overlay(alignment: .bottom) {
            if isSelectMode {
                selectionActionBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var topActionBar: some View {
        HStack(alignment: .center, spacing: 12) {
            // Back navigation
            if !isSearching {
                if let parent = parentFolder {
                    backButton(title: parent.name) { navigateToFolder(id: parent.id) }
                } else if currentFolder != nil || sidebarSelection != .home {
                    backButton(title: "Home") { selectSidebar(.home) }
                }
            }

            Spacer()

            if isTrashView {
                if !currentDocuments.isEmpty {
                    selectButton
                    Button {
                        showEmptyTrashConfirm = true
                    } label: {
                        Text("Empty")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .foregroundColor(Color(hex: "#B54D35"))
                            .background(Color(hex: "#B54D35").opacity(0.1))
                            .cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(hex: "#B54D35").opacity(0.6), lineWidth: 1))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            } else {
                // Sort menu
                Menu {
                    Picker("Sort by", selection: $sortOrder) {
                        ForEach(LibrarySortOrder.allCases) { order in
                            Text(order.label).tag(order)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 14))
                        .frame(width: 34, height: 34)
                        .background(isDark ? Color(hex: "#282727") : Color.white)
                        .foregroundColor(FolioTheme.text(isDark: isDark))
                        .cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(FolioTheme.divider(isDark: isDark), lineWidth: 1))
                }
                .accessibilityLabel("Sort")

                if !currentDocuments.isEmpty {
                    selectButton
                }

                // "+ New" Primary Button (with Dropdown Menu)
                Menu {
                    Button {
                        showNewNotebookSheet = true
                    } label: {
                        Label("Notebook", systemImage: "book.closed")
                    }

                    Button {
                        showPDFImporter = true
                    } label: {
                        Label("Import PDF", systemImage: "arrow.down.doc")
                    }

                    Button {
                        newFolderRequest = NewFolderRequest(parentId: currentFolderId)
                    } label: {
                        Label(currentFolder.map { "Folder in \($0.name)" } ?? "New Folder", systemImage: "folder.badge.plus")
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .bold))
                        Text("New")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(FolioTheme.accent(isDark: isDark).opacity(0.14))
                    .foregroundColor(FolioTheme.accent(isDark: isDark))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(FolioTheme.accent(isDark: isDark), lineWidth: 1)
                    )
                }
            }
        }
        .frame(minHeight: 36)
    }

    private var selectButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                if isSelectMode {
                    exitSelectMode()
                } else {
                    isSelectMode = true
                }
            }
        } label: {
            Text(isSelectMode ? "Done" : "Select")
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(isDark ? Color(hex: "#282727") : Color.white)
                .foregroundColor(FolioTheme.text(isDark: isDark))
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(FolioTheme.divider(isDark: isDark), lineWidth: 1))
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func backButton(title: String, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.spring(response: 0.25)) {
                action()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .bold))
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(FolioTheme.accent(isDark: isDark))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(FolioTheme.accent(isDark: isDark).opacity(0.1))
            .cornerRadius(6)
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func breadcrumbs(for folderId: UUID) -> some View {
        let path = store.breadcrumbPath(for: folderId)
        return HStack(spacing: 6) {
            Button("Home") { selectSidebar(.home) }
                .foregroundColor(FolioTheme.accent(isDark: isDark))
            ForEach(path) { folder in
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(FolioTheme.textSecondary(isDark: isDark))
                if folder.id == folderId {
                    Text(folder.name)
                        .foregroundColor(FolioTheme.textSecondary(isDark: isDark))
                } else {
                    Button(folder.name) { navigateToFolder(id: folder.id) }
                        .foregroundColor(FolioTheme.accent(isDark: isDark))
                }
            }
        }
        .font(.system(size: 13))
        .lineLimit(1)
    }

    private var emptyState: some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: isTrashView ? "trash" : "doc.text")
                    .font(.system(size: 32))
                    .foregroundColor(FolioTheme.textSecondary(isDark: isDark).opacity(0.5))
                Text(emptyMessage)
                    .font(.system(size: 14))
                    .foregroundColor(FolioTheme.textSecondary(isDark: isDark))
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 40)
            Spacer()
        }
    }

    private var documentGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 22)], alignment: .leading, spacing: 24) {
            ForEach(currentDocuments) { doc in
                FolioDocumentTile(
                    document: doc,
                    subtitle: tileSubtitle(for: doc),
                    isDark: isDark,
                    isSelectMode: isSelectMode,
                    isSelected: selectedDocIds.contains(doc.id),
                    onSelect: {
                        if isSelectMode {
                            toggleSelection(doc.id)
                        } else if doc.isInTrash {
                            // Deleted documents open only after restoring them.
                            toggleSelectionMode(with: doc.id)
                        } else {
                            activeDocumentId = doc.id
                        }
                    }
                ) {
                    if doc.isInTrash {
                        trashContextMenu(for: doc)
                    } else {
                        documentContextMenu(for: doc)
                    }
                }
            }

            // Quick "Blank Notebook" One-Tap Tile
            if isBrowsingFolder && !isSelectMode {
                FolioBlankNotebookTile(isDark: isDark) {
                    let newDoc = store.createNotebook(
                        title: "Untitled Notebook",
                        folderId: currentFolderId,
                        template: .ruled,
                        paperColor: .ivory,
                        coverColorHex: "#b68235"
                    )
                    activeDocumentId = newDoc.id
                }
            }
        }
    }

    private func tileSubtitle(for doc: NoteDocument) -> String {
        let kind = doc.type == .pdfDocument ? "PDF" : "Notebook"
        let pages = "\(doc.pageCount) \(doc.pageCount == 1 ? "page" : "pages")"
        if let deleted = doc.deletedDate {
            let days = Calendar.current.dateComponents([.day], from: deleted, to: Date()).day ?? 0
            let remaining = max(0, DocumentStore.trashRetentionDays - days)
            return "\(kind) · \(remaining) \(remaining == 1 ? "day" : "days") left"
        }
        if isSearching || sidebarSelection == .recent || sidebarSelection == .favorites {
            let folderName = store.folder(for: doc.folderId)?.name ?? "Home"
            return "\(kind) · \(folderName)"
        }
        return "\(kind) · \(pages)"
    }

    @ViewBuilder
    private func documentContextMenu(for doc: NoteDocument) -> some View {
        Button {
            activeDocumentId = doc.id
        } label: {
            Label("Open", systemImage: "pencil.tip")
        }
        Button {
            renameText = doc.title
            renameTarget = .document(doc)
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button {
            moveTarget = .documents([doc.id], currentFolderId: doc.folderId)
        } label: {
            Label("Move to…", systemImage: "folder")
        }
        Button {
            store.duplicateDocument(id: doc.id)
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        Button {
            store.toggleFavorite(documentId: doc.id)
        } label: {
            Label(doc.isFavorite ? "Remove from Favorites" : "Favorite", systemImage: doc.isFavorite ? "star.slash" : "star")
        }
        Divider()
        Button(role: .destructive) {
            store.deleteDocument(id: doc.id)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func trashContextMenu(for doc: NoteDocument) -> some View {
        Button {
            store.restoreDocument(id: doc.id)
        } label: {
            Label("Restore", systemImage: "arrow.uturn.backward")
        }
        Divider()
        Button(role: .destructive) {
            docsPendingPermanentDelete = [doc.id]
        } label: {
            Label("Delete Permanently", systemImage: "trash")
        }
    }

    // MARK: - Selection Mode

    private var selectionActionBar: some View {
        let count = selectedDocIds.count
        let allIds = currentDocuments.map { $0.id }
        let allSelected = !allIds.isEmpty && Set(allIds).isSubset(of: selectedDocIds)

        return HStack(spacing: 14) {
            Button(allSelected ? "Deselect All" : "Select All") {
                selectedDocIds = allSelected ? [] : Set(allIds)
            }
            .foregroundColor(FolioTheme.accent(isDark: isDark))

            Text(count == 0 ? "Select documents" : "\(count) selected")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(FolioTheme.textSecondary(isDark: isDark))

            Spacer()

            if isTrashView {
                selectionBarButton("Restore", icon: "arrow.uturn.backward", enabled: count > 0) {
                    selectedDocIds.forEach { store.restoreDocument(id: $0) }
                    exitSelectMode()
                }
                selectionBarButton("Delete", icon: "trash", enabled: count > 0, destructive: true) {
                    docsPendingPermanentDelete = Array(selectedDocIds)
                }
            } else {
                selectionBarButton("Move", icon: "folder", enabled: count > 0) {
                    moveTarget = .documents(Array(selectedDocIds), currentFolderId: currentFolderId)
                }
                selectionBarButton("Delete", icon: "trash", enabled: count > 0, destructive: true) {
                    selectedDocIds.forEach { store.deleteDocument(id: $0) }
                    exitSelectMode()
                }
            }

            Button("Done") {
                withAnimation(.easeInOut(duration: 0.2)) { exitSelectMode() }
            }
            .fontWeight(.semibold)
            .foregroundColor(FolioTheme.accent(isDark: isDark))
        }
        .font(.system(size: 14))
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(isDark ? Color(hex: "#242323") : Color.white)
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(FolioTheme.divider(isDark: isDark), lineWidth: 1))
        .shadow(color: Color.black.opacity(isDark ? 0.4 : 0.12), radius: 12, x: 0, y: 4)
        .padding(.horizontal, 40)
        .padding(.bottom, 20)
    }

    private func selectionBarButton(_ title: String, icon: String, enabled: Bool, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(destructive ? Color(hex: "#B54D35") : FolioTheme.text(isDark: isDark))
                .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!enabled)
    }

    private func toggleSelection(_ id: UUID) {
        if selectedDocIds.contains(id) {
            selectedDocIds.remove(id)
        } else {
            selectedDocIds.insert(id)
        }
    }

    private func toggleSelectionMode(with id: UUID) {
        withAnimation(.easeInOut(duration: 0.2)) {
            isSelectMode = true
            selectedDocIds = [id]
        }
    }

    private func exitSelectMode() {
        isSelectMode = false
        selectedDocIds = []
    }

    // MARK: - Move Sheet

    @ViewBuilder
    private func moveSheet(for target: MoveTarget) -> some View {
        switch target {
        case .folder(let folder):
            FolderPickerSheet(
                currentFolderId: folder.parentId,
                store: store,
                isDark: isDark,
                excludedFolderIds: store.descendantFolderIds(of: folder.id),
                title: "Move “\(folder.name)”"
            ) { destination in
                store.moveFolder(id: folder.id, to: destination)
                moveTarget = nil
            }
        case .documents(let ids, let currentFolderId):
            FolderPickerSheet(
                currentFolderId: ids.count == 1 ? currentFolderId : nil,
                store: store,
                isDark: isDark,
                title: ids.count == 1 ? "Move to Folder" : "Move \(ids.count) Documents"
            ) { destination in
                ids.forEach { store.moveDocument(id: $0, to: destination) }
                moveTarget = nil
                exitSelectMode()
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }
    }

    // MARK: - Actions

    private func selectSidebar(_ selection: SidebarSelection) {
        store.searchQuery = ""
        sidebarSelection = selection
    }

    private func navigateToFolder(id: UUID) {
        selectSidebar(.folder(id))
    }

    private func commitRename() {
        guard let target = renameTarget else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        switch target {
        case .folder(let folder):
            store.renameFolder(id: folder.id, to: name)
        case .document(let doc):
            store.renameDocument(id: doc.id, newTitle: name)
        }
    }

    private func folderDeletionMessage(_ folder: Folder) -> String {
        let summary = store.deletionSummary(forFolder: folder.id)
        var parts: [String] = []
        if summary.subfolders > 0 {
            parts.append("\(summary.subfolders) \(summary.subfolders == 1 ? "subfolder" : "subfolders")")
        }
        if summary.documents > 0 {
            parts.append("\(summary.documents) \(summary.documents == 1 ? "document" : "documents")")
        }
        if parts.isEmpty {
            return "This folder is empty."
        }
        var message = "This folder contains \(parts.joined(separator: " and "))."
        if summary.documents > 0 {
            message += " Documents will be moved to Recently Deleted, where you can restore them for \(DocumentStore.trashRetentionDays) days."
        }
        return message
    }

    private func deleteFolder(_ folder: Folder) {
        let removed = store.descendantFolderIds(of: folder.id)
        if let current = currentFolderId, removed.contains(current) {
            sidebarSelection = folder.parentId.map { .folder($0) } ?? .home
        }
        withAnimation(.spring(response: 0.3)) {
            store.deleteFolder(id: folder.id)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            var imported: [NoteDocument] = []
            var failures: [String] = []
            for url in urls {
                do {
                    imported.append(try store.importPDF(from: url, into: currentFolderId))
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if !failures.isEmpty {
                importErrorMessage = failures.joined(separator: "\n")
            } else if imported.count == 1, let doc = imported.first {
                activeDocumentId = doc.id
            }
        case .failure(let error):
            importErrorMessage = error.localizedDescription
        }
    }

    private func formattedCurrentTime() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm  E MMM d"
        return formatter.string(from: Date())
    }

    private func isPresentedBinding<T>(_ item: Binding<T?>) -> Binding<Bool> {
        Binding(
            get: { item.wrappedValue != nil },
            set: { if !$0 { item.wrappedValue = nil } }
        )
    }
}

// MARK: - Library Helper Types

public enum SidebarSelection: Hashable {
    case home
    case recent
    case favorites
    case trash
    case folder(UUID)
}

enum LibrarySortOrder: String, CaseIterable, Identifiable {
    case lastModified, title, dateCreated

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lastModified: return "Last Modified"
        case .title: return "Title"
        case .dateCreated: return "Date Created"
        }
    }
}

struct NewFolderRequest: Identifiable {
    let id = UUID()
    let parentId: UUID?
}

enum RenameTarget {
    case folder(Folder)
    case document(NoteDocument)

    var alertTitle: String {
        switch self {
        case .folder: return "Rename Folder"
        case .document(let doc): return doc.type == .pdfDocument ? "Rename PDF" : "Rename Notebook"
        }
    }
}

enum MoveTarget: Identifiable {
    case folder(Folder)
    case documents([UUID], currentFolderId: UUID?)

    var id: String {
        switch self {
        case .folder(let f): return "folder-\(f.id)"
        case .documents(let ids, _): return "docs-" + ids.map(\.uuidString).joined(separator: ",")
        }
    }
}

struct FolderActions {
    let open: (Folder) -> Void
    let newSubfolder: (Folder) -> Void
    let rename: (Folder) -> Void
    let move: (Folder) -> Void
    let delete: (Folder) -> Void
}

extension View {
    /// Long-press menu for managing a folder (used by sidebar rows and folder cards).
    func folderContextMenu(_ folder: Folder, actions: FolderActions) -> some View {
        contextMenu {
            Button {
                actions.open(folder)
            } label: {
                Label("Open", systemImage: "folder")
            }
            Button {
                actions.newSubfolder(folder)
            } label: {
                Label("New Subfolder", systemImage: "folder.badge.plus")
            }
            Button {
                actions.rename(folder)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button {
                actions.move(folder)
            } label: {
                Label("Move to…", systemImage: "arrow.right.doc.on.clipboard")
            }
            Divider()
            Button(role: .destructive) {
                actions.delete(folder)
            } label: {
                Label("Delete Folder…", systemImage: "trash")
            }
        }
    }
}

// MARK: - Sidebar Quick Row

struct SidebarQuickRow: View {
    let icon: String
    let title: String
    let count: Int
    let isSelected: Bool
    let isDark: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundColor(isSelected ? FolioTheme.accent(isDark: isDark) : FolioTheme.text(isDark: isDark))
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(FolioTheme.text(isDark: isDark))
                Spacer()
                Text("\(count)")
                    .font(.system(size: 12))
                    .foregroundColor(FolioTheme.textSecondary(isDark: isDark))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isSelected ? FolioTheme.accent(isDark: isDark).opacity(0.12) : Color.clear)
            .cornerRadius(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Recursive Sidebar Folder Row

struct FolioFolderTreeRow: View {
    let folder: Folder
    @ObservedObject var store: DocumentStore
    @Binding var selection: SidebarSelection
    let level: Int
    let isDark: Bool
    let actions: FolderActions

    @State private var isExpanded: Bool = true

    private var subfolders: [Folder] {
        store.subfolders(of: folder.id)
    }

    private var isSelected: Bool {
        if case .folder(let id) = selection, id == folder.id {
            return true
        }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                if level > 0 {
                    Spacer().frame(width: CGFloat(level * 16))
                }

                if !subfolders.isEmpty {
                    Button {
                        withAnimation(.spring(response: 0.25)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(FolioTheme.textSecondary(isDark: isDark))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                } else {
                    Spacer().frame(width: 20)
                }

                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: folder.colorHex).opacity(0.85))

                Text(folder.name)
                    .font(.system(size: 13.5, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? FolioTheme.accent(isDark: isDark) : FolioTheme.text(isDark: isDark))
                    .lineLimit(1)

                Spacer()

                Text("\(store.itemCount(inFolder: folder.id))")
                    .font(.system(size: 11))
                    .foregroundColor(FolioTheme.textSecondary(isDark: isDark))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                isSelected ?
                FolioTheme.accent(isDark: isDark).opacity(0.12) :
                Color.clear
            )
            .cornerRadius(5)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(isSelected ? FolioTheme.accent(isDark: isDark).opacity(0.4) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                actions.open(folder)
            }
            .folderContextMenu(folder, actions: actions)

            if isExpanded && !subfolders.isEmpty {
                ForEach(subfolders) { sub in
                    FolioFolderTreeRow(
                        folder: sub,
                        store: store,
                        selection: $selection,
                        level: level + 1,
                        isDark: isDark,
                        actions: actions
                    )
                }
            }
        }
    }
}

// MARK: - Folder Card (Mockup 1a)

struct FolioFolderCard: View {
    let folder: Folder
    @ObservedObject var store: DocumentStore
    let isDark: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "folder")
                    .font(.system(size: 22))
                    .foregroundColor(FolioTheme.accent(isDark: isDark))

                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name)
                        .font(FolioTheme.serifHeading(size: 15, weight: .semibold))
                        .foregroundColor(FolioTheme.text(isDark: isDark))
                        .lineLimit(1)

                    let count = store.itemCount(inFolder: folder.id)
                    Text("\(count) \(count == 1 ? "item" : "items")")
                        .font(.system(size: 11))
                        .foregroundColor(FolioTheme.textSecondary(isDark: isDark))
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(width: 190, height: 60)
            .background(isDark ? Color(hex: "#252424") : Color.white)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(FolioTheme.divider(isDark: isDark), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - 3:4 Document Preview Tile (Mockup 1a)

struct FolioDocumentTile<MenuItems: View>: View {
    let document: NoteDocument
    let subtitle: String
    let isDark: Bool
    let isSelectMode: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    @ViewBuilder let menuItems: () -> MenuItems

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                // 3:4 Aspect Ratio Paper Thumbnail
                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isDark ? Color(hex: "#232222") : Color(hex: "#f8f4f4"))
                        .overlay(
                            // Ruled lines pattern on paper
                            VStack(spacing: 6) {
                                ForEach(0..<14, id: \.self) { _ in
                                    Rectangle()
                                        .fill(isDark ? Color(hex: "#343232") : Color(hex: "#e4dfdf"))
                                        .frame(height: 1)
                                }
                            }
                            .padding(.top, 14)
                            .padding(.horizontal, 10)
                        )
                        .overlay(
                            // Handwriting preview text
                            VStack(alignment: .leading, spacing: 4) {
                                Text(document.title)
                                    .font(FolioTheme.serifHeading(size: 13, weight: .semibold))
                                    .foregroundColor(isDark ? Color(hex: "#9bb4eb") : Color(hex: "#2A3F70"))
                                    .lineLimit(2)
                                    .padding(.top, 14)
                                    .padding(.horizontal, 12)
                                Spacer()
                            }
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(isSelected ? FolioTheme.accent(isDark: isDark) : FolioTheme.divider(isDark: isDark), lineWidth: isSelected ? 2.5 : 1)
                        )
                        .aspectRatio(3.0 / 4.0, contentMode: .fit)
                        .shadow(color: Color.black.opacity(isDark ? 0.3 : 0.08), radius: 4, x: 0, y: 2)
                        .opacity(document.isInTrash ? 0.6 : 1)

                    if document.type == .pdfDocument {
                        Text("PDF")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(FolioTheme.accent(isDark: isDark).opacity(0.18))
                            .foregroundColor(FolioTheme.accent(isDark: isDark))
                            .cornerRadius(3)
                            .padding(8)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isSelectMode {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 22))
                            .foregroundColor(isSelected ? FolioTheme.accent(isDark: isDark) : FolioTheme.textSecondary(isDark: isDark))
                            .background(Circle().fill(isDark ? Color(hex: "#232222") : Color.white).padding(2))
                            .padding(8)
                    } else if document.isFavorite && !document.isInTrash {
                        Image(systemName: "star.fill")
                            .font(.system(size: 12))
                            .foregroundColor(FolioTheme.accent(isDark: isDark))
                            .padding(10)
                    }
                }

                // Metadata below
                VStack(alignment: .leading, spacing: 2) {
                    Text(document.title)
                        .font(FolioTheme.serifHeading(size: 14.5, weight: .semibold))
                        .foregroundColor(FolioTheme.text(isDark: isDark))
                        .lineLimit(1)

                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(FolioTheme.textSecondary(isDark: isDark))
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .contextMenu {
            if !isSelectMode {
                menuItems()
            }
        }
    }
}

// MARK: - One-Tap Blank Notebook Tile (Mockup 1a)

struct FolioBlankNotebookTile: View {
    let isDark: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                // Dashed outline 3:4 tile
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            isDark ? Color(hex: "#504e4e") : Color(hex: "#bab6b6"),
                            style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                        )
                        .background(isDark ? Color(hex: "#1e1d1d").opacity(0.4) : Color.white.opacity(0.3))
                        .aspectRatio(3.0 / 4.0, contentMode: .fit)

                    Image(systemName: "plus")
                        .font(.system(size: 24, weight: .light))
                        .foregroundColor(FolioTheme.accent(isDark: isDark))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Blank notebook")
                        .font(FolioTheme.serifHeading(size: 14.5, weight: .semibold))
                        .foregroundColor(FolioTheme.accent(isDark: isDark))

                    Text("Ruled · tap to start writing")
                        .font(.system(size: 11))
                        .foregroundColor(FolioTheme.textSecondary(isDark: isDark))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
}
