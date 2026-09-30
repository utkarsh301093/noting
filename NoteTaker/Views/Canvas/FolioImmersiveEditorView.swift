import SwiftUI
import PencilKit
import PDFKit

/// Folio Immersive Writing Screen (Mockup 1b, 1c, 1d, 1e)
/// Zero-chrome continuous vertical notebook layout:
/// - Pages render full-width, stacked vertically; drawings live in a fixed logical page space
///   (see `PageGeometry`) so ink stays aligned across rotation and margin toggling.
/// - Top-Left: "‹ Library" button (also Esc on a keyboard) and the Files chip (Document Properties & File Manager).
/// - Top-Center: Toolbar capsule (zoom window, snap-to-shape, paper, bookmark, undo/redo, margin, input, theme, focus).
/// - Top-Right: Pages chip (current page / total, opens the thumbnail grid).
/// - PDFs get an optional writable side margin that can be hidden for full-width reading.
/// - Focus mode hides all chrome; a single small button brings it back.
public struct FolioImmersiveEditorView: View {
    public let documentId: UUID
    @ObservedObject public var store = DocumentStore.shared
    @ObservedObject public var theme = ThemeManager.shared
    public var onBackToLibrary: () -> Void
    public var onOpenDocument: (UUID) -> Void

    // Canvas & Hardware controller
    @StateObject private var canvasController = CanvasController()

    // Floating UI visibility
    @State private var isChromeVisible: Bool = true
    @State private var showDocumentProperties: Bool = false
    @State private var showQuickSwitcher: Bool = false
    @State private var showThumbnails: Bool = false
    @State private var showTemplatePicker: Bool = false
    @AppStorage("folio.toolPickerVisible") private var isToolPickerVisible: Bool = true
    @AppStorage("folio.allowFingerDrawing") private var allowsFingerDrawing: Bool = false
    @AppStorage("folio.snapToShapes") private var snapsToShapes: Bool = true
    @State private var showSnapHint: Bool = false

    // PDF Export
    @State private var exportedPDFURL: URL? = nil
    @State private var showShareSheet: Bool = false
    @State private var isExporting: Bool = false

    // Page tracking
    @State private var scrolledPageId: UUID? = nil
    @State private var activePageId: UUID? = nil

    // Zoom Window State (Mockup 1d handwriting dock)
    @StateObject private var zoomState = ZoomWindowState()
    @State private var activeZoomDrawing: PKDrawing = PKDrawing()

    private var isDark: Bool { theme.isDarkMode }

    private var document: NoteDocument? {
        store.documents.first { $0.id == documentId }
    }

    /// The page tools act on: the one last written on, else the one scrolled into view.
    private var activePage: NotePage? {
        guard let doc = document else { return nil }
        return doc.pages.first { $0.id == activePageId } ?? doc.pages.first
    }

    private var activePageNumber: Int {
        guard let doc = document, let page = activePage,
              let idx = doc.pages.firstIndex(where: { $0.id == page.id }) else { return 1 }
        return idx + 1
    }

    public init(
        documentId: UUID,
        onBackToLibrary: @escaping () -> Void,
        onOpenDocument: @escaping (UUID) -> Void = { _ in }
    ) {
        self.documentId = documentId
        self.onBackToLibrary = onBackToLibrary
        self.onOpenDocument = onOpenDocument
    }

    public var body: some View {
        ZStack(alignment: .top) {
            if let doc = document {
                pageStack(doc: doc)

                if isChromeVisible {
                    topChrome(doc: doc)
                        .transition(.opacity)
                } else {
                    exitFocusButton
                        .transition(.opacity)
                }

                if showSnapHint {
                    Text("Snap to shape is on — draw a line or shape and hold the pencil still for 2 seconds.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.8))
                        .cornerRadius(20)
                        .padding(.top, 80)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }

                // MARK: - Screen 1c: Quick Switcher Slide-out Panel
                if showQuickSwitcher {
                    HStack(spacing: 0) {
                        FolioQuickSwitcherPanel(
                            currentDoc: doc,
                            store: store,
                            isDark: isDark,
                            onClose: {
                                withAnimation(.spring(response: 0.3)) {
                                    showQuickSwitcher = false
                                }
                            },
                            onSelectDoc: { newDoc in
                                switchDocument(to: newDoc)
                            },
                            onBackToLibrary: onBackToLibrary
                        )
                        Spacer()
                    }
                    .padding(.leading, 20)
                    .padding(.top, 78)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }

                // MARK: - Screen 1d: Zoom Window (Handwriting Magnifier Dock)
                if zoomState.isVisible, let targetPage = activePage {
                    VStack {
                        Spacer()
                        ZoomWritingWindowView(
                            state: zoomState,
                            templateType: targetPage.pdfPageIndex == nil ? targetPage.templateType : .blank,
                            paperColor: displayedPaper(for: targetPage),
                            pdfURL: targetPage.pdfPageIndex == nil ? nil : doc.pdfFileName.map { store.pdfURL(for: $0) },
                            pdfPageIndex: targetPage.pdfPageIndex,
                            drawing: $activeZoomDrawing,
                            isPencilOnly: !allowsFingerDrawing,
                            snapsToShapes: snapsToShapes,
                            isDark: isDark,
                            controller: canvasController,
                            onDrawingChanged: { updated in
                                // Same drawing as the page: save it and let the page canvas pick it up live.
                                store.saveDrawing(updated, for: targetPage, notifyCanvases: true)
                            }
                        )
                        .id(targetPage.id)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            } else {
                // Document was deleted or is missing
                VStack(spacing: 12) {
                    Text("This document is no longer available.")
                        .foregroundColor(FolioTheme.textSecondary(isDark: isDark))
                    Button("Back to Library", action: onBackToLibrary)
                        .foregroundColor(FolioTheme.accent(isDark: isDark))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(FolioTheme.surface(isDark: isDark))
            }
        }
        .onAppear {
            if activePageId == nil {
                activePageId = document?.pages.first?.id
            }
        }
        .onChange(of: scrolledPageId) {
            if let id = scrolledPageId {
                activePageId = id
            }
        }
        .onChange(of: activePageId) {
            refreshZoomTarget()
        }
        .onChange(of: zoomState.isVisible) {
            refreshZoomTarget()
        }
        .sheet(isPresented: $showDocumentProperties) {
            if let doc = document {
                FolioDocumentPropertiesSheet(
                    documentId: doc.id,
                    store: store,
                    isDark: isDark,
                    onClose: {
                        showDocumentProperties = false
                    },
                    onOpenQuickSwitcher: {
                        showDocumentProperties = false
                        withAnimation(.spring(response: 0.35)) {
                            showQuickSwitcher = true
                        }
                    },
                    onDocumentDeleted: {
                        onBackToLibrary()
                    },
                    onExportPDF: {
                        exportToPDF()
                    }
                )
            }
        }
        .sheet(isPresented: $showThumbnails) {
            if let doc = document {
                PageThumbnailsSheet(
                    document: doc,
                    store: store,
                    currentPageId: activePage?.id,
                    onSelectPage: { pageId in
                        jumpToPage(pageId)
                    }
                )
            }
        }
        .sheet(isPresented: $showTemplatePicker) {
            if let doc = document, let page = activePage {
                TemplatePickerSheet(
                    selectedTemplate: Binding(
                        get: { page.templateType },
                        set: { store.updatePagePaper(pageId: page.id, in: doc.id, template: $0) }
                    ),
                    selectedPaperColor: Binding(
                        get: { page.paperColor },
                        set: { store.updatePagePaper(pageId: page.id, in: doc.id, color: $0) }
                    ),
                    onApplyToAllPages: {
                        let current = store.documents.first { $0.id == doc.id }?.pages.first { $0.id == page.id } ?? page
                        store.applyPaperToAllPages(in: doc.id, template: current.templateType, color: current.paperColor)
                    }
                )
            }
        }
        .sheet(isPresented: $showShareSheet, onDismiss: {
            // Don't leave exported copies of notes lying around in temporary storage.
            if let url = exportedPDFURL {
                try? FileManager.default.removeItem(at: url)
                exportedPDFURL = nil
            }
        }) {
            if let url = exportedPDFURL {
                ShareSheet(items: [url])
            }
        }
    }

    // MARK: - Page Stack

    @ViewBuilder
    private func pageStack(doc: NoteDocument) -> some View {
        GeometryReader { geo in
            let showMargin = doc.type == .pdfDocument && doc.isMarginVisible
            let horizontalPadding: CGFloat = isChromeVisible ? 16 : 8
            let marginGap: CGFloat = showMargin ? 8 : 0
            let logicalWidth = PageGeometry.logicalWidth + (showMargin ? PageGeometry.marginLogicalWidth : 0)
            let availableWidth = max(320, geo.size.width - horizontalPadding * 2 - marginGap)
            let scale = availableWidth / logicalWidth

            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 0) {
                    LazyVStack(spacing: 24) {
                        ForEach(doc.pages) { page in
                            FolioPageCanvasCard(
                                page: page,
                                doc: doc,
                                scale: scale,
                                isDark: isDark,
                                showMargin: showMargin,
                                allowsFingerDrawing: allowsFingerDrawing,
                                showsToolPicker: isToolPickerVisible,
                                snapsToShapes: snapsToShapes,
                                isZoomTarget: page.id == activePage?.id,
                                store: store,
                                canvasController: canvasController,
                                zoomState: zoomState,
                                onActivate: {
                                    activePageId = page.id
                                },
                                onDrawingSaved: { saved in
                                    if zoomState.isVisible && page.id == activePage?.id {
                                        activeZoomDrawing = saved
                                    }
                                }
                            )
                            .id(page.id)
                        }
                    }
                    .scrollTargetLayout()

                    // Prominent [ + Add Page ] button at the bottom
                    Button {
                        addNewPage(atEnd: true)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(FolioTheme.accent(isDark: isDark))

                            Text("Add Page \(doc.pages.count + 1)")
                                .font(FolioTheme.serifHeading(size: 16, weight: .semibold))
                                .foregroundColor(FolioTheme.text(isDark: isDark))
                        }
                        .padding(.horizontal, 32)
                        .padding(.vertical, 14)
                        .background(isDark ? Color(hex: "#242323") : Color.white)
                        .cornerRadius(24)
                        .overlay(
                            Capsule()
                                .stroke(FolioTheme.accent(isDark: isDark).opacity(0.4), lineWidth: 1.5)
                        )
                        .shadow(color: Color.black.opacity(isDark ? 0.35 : 0.08), radius: 8, x: 0, y: 3)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding(.top, 40)
                    .padding(.bottom, zoomState.isVisible ? 340 : 120)
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, isChromeVisible ? 80 : 16)
            }
            .scrollPosition(id: $scrolledPageId, anchor: .top)
        }
        .background(FolioTheme.surface(isDark: isDark))
    }

    // MARK: - Top Chrome (Screen 1b)

    @ViewBuilder
    private func topChrome(doc: NoteDocument) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // 1. TOP-LEFT: Back to Library + Files Chip (Document Properties & File Manager)
            backToLibraryButton

            Button {
                showDocumentProperties = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: doc.folderId == nil ? "house" : "folder")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(FolioTheme.accent(isDark: isDark))

                    Text(doc.title)
                        .font(FolioTheme.serifHeading(size: 16, weight: .regular))
                        .italic()
                        .foregroundColor(FolioTheme.text(isDark: isDark))
                        .lineLimit(1)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(FolioTheme.textSecondary(isDark: isDark))
                }
                .padding(.horizontal, 14)
                .frame(height: 48)
                .background(isDark ? Color(hex: "#242323") : Color.white)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(showDocumentProperties ? FolioTheme.accent(isDark: isDark) : FolioTheme.divider(isDark: isDark), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(isDark ? 0.3 : 0.08), radius: 6, x: 0, y: 2)
            }
            .buttonStyle(PlainButtonStyle())
            .layoutPriority(-1)

            Spacer(minLength: 0)

            // 2. TOP-CENTER: Floating Toolbar Capsule
            FolioFloatingToolbarCapsule(
                isDark: isDark,
                zoomActive: zoomState.isVisible,
                snapActive: snapsToShapes,
                canEditPaper: activePage?.pdfPageIndex == nil,
                isBookmarked: activePage?.isBookmarked ?? false,
                isPdf: doc.type == .pdfDocument,
                marginVisible: doc.isMarginVisible,
                fingerDrawing: allowsFingerDrawing,
                paletteActive: isToolPickerVisible,
                onToggleZoom: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        zoomState.isVisible.toggle()
                    }
                },
                onToggleSnap: {
                    snapsToShapes.toggle()
                    if snapsToShapes {
                        flashSnapHint()
                    }
                },
                onPaperSettings: {
                    showTemplatePicker = true
                },
                onAddPage: {
                    addNewPage(atEnd: false)
                },
                onToggleBookmark: {
                    if let page = activePage {
                        store.toggleBookmark(pageId: page.id, in: doc.id)
                    }
                },
                onUndo: {
                    canvasController.undo()
                },
                onRedo: {
                    canvasController.redo()
                },
                onToggleMargin: {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        store.setMarginVisible(!doc.isMarginVisible, for: doc.id)
                    }
                },
                onToggleFingerDrawing: {
                    allowsFingerDrawing.toggle()
                },
                onTogglePalette: {
                    isToolPickerVisible.toggle()
                },
                onToggleTheme: {
                    theme.toggleTheme()
                },
                onEnterFocus: {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        showQuickSwitcher = false
                        isChromeVisible = false
                    }
                }
            )
            .layoutPriority(1)

            Spacer(minLength: 0)

            // 3. TOP-RIGHT: Pages Chip (current page / total, opens thumbnail grid)
            Button {
                showThumbnails = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: activePage?.isBookmarked == true ? "bookmark.fill" : "doc.on.doc")
                        .font(.system(size: 13))
                        .foregroundColor(FolioTheme.accent(isDark: isDark))

                    Text("\(activePageNumber) / \(doc.pages.count)")
                        .font(.system(size: 13, weight: .medium, design: .serif))
                        .foregroundColor(FolioTheme.text(isDark: isDark))
                        .monospacedDigit()
                }
                .padding(.horizontal, 14)
                .frame(height: 48)
                .background(isDark ? Color(hex: "#242323") : Color.white)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(FolioTheme.divider(isDark: isDark), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(isDark ? 0.3 : 0.08), radius: 6, x: 0, y: 2)
            }
            .buttonStyle(PlainButtonStyle())
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
    }

    /// "‹ Library" — the one obvious way out of a notebook. Esc on a hardware keyboard does the same.
    private var backToLibraryButton: some View {
        Button(action: onBackToLibrary) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                Text("Library")
                    .font(.system(size: 15, weight: .medium))
            }
            .foregroundColor(FolioTheme.accent(isDark: isDark))
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(isDark ? Color(hex: "#242323") : Color.white)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(FolioTheme.divider(isDark: isDark), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(isDark ? 0.3 : 0.08), radius: 6, x: 0, y: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .keyboardShortcut(.escape, modifiers: [])
        .accessibilityLabel("Back to Library")
        .fixedSize()
    }

    private func flashSnapHint() {
        withAnimation(.easeOut(duration: 0.2)) { showSnapHint = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
            withAnimation(.easeIn(duration: 0.3)) { showSnapHint = false }
        }
    }

    /// Small buttons shown in focus mode: back to the library, and bring the chrome back.
    private var exitFocusButton: some View {
        HStack {
            Button(action: onBackToLibrary) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(FolioTheme.text(isDark: isDark))
                    .frame(width: 40, height: 40)
                    .background((isDark ? Color(hex: "#242323") : Color.white).opacity(0.85))
                    .clipShape(Circle())
                    .overlay(Circle().stroke(FolioTheme.divider(isDark: isDark), lineWidth: 1))
                    .shadow(color: Color.black.opacity(0.12), radius: 4, x: 0, y: 2)
            }
            .buttonStyle(PlainButtonStyle())
            .keyboardShortcut(.escape, modifiers: [])
            .accessibilityLabel("Back to Library")
            .padding(.leading, 16)

            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isChromeVisible = true
                }
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(FolioTheme.text(isDark: isDark))
                    .frame(width: 40, height: 40)
                    .background((isDark ? Color(hex: "#242323") : Color.white).opacity(0.85))
                    .clipShape(Circle())
                    .overlay(Circle().stroke(FolioTheme.divider(isDark: isDark), lineWidth: 1))
                    .shadow(color: Color.black.opacity(0.12), radius: 4, x: 0, y: 2)
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel("Exit focus mode")
        }
        .padding(.trailing, 16)
        .padding(.top, 12)
    }

    // MARK: - Actions & Operations

    private func displayedPaper(for page: NotePage) -> PaperColor {
        if page.pdfPageIndex != nil { return .white }
        return isDark ? .dark : page.paperColor
    }

    private func addNewPage(atEnd: Bool) {
        guard let doc = document else { return }
        // New pages copy the paper of the nearest notebook page (PDF docs fall back to the document default).
        let reference = (atEnd ? doc.pages.last : activePage).flatMap { $0.pdfPageIndex == nil ? $0 : nil }
        let template = reference?.templateType ?? doc.defaultTemplate
        let paperColor = reference?.paperColor ?? doc.defaultPaperColor
        var insertIndex: Int? = nil
        if !atEnd, let active = activePage, let idx = doc.pages.firstIndex(where: { $0.id == active.id }) {
            insertIndex = idx + 1
        }

        if let newPage = store.addPage(to: doc.id, templateType: template, paperColor: paperColor, at: insertIndex) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            activePageId = newPage.id
            jumpToPage(newPage.id)
        }
    }

    private func jumpToPage(_ pageId: UUID) {
        activePageId = pageId
        // Let the page list update (e.g. after inserting a page) before scrolling.
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.3)) {
                scrolledPageId = pageId
            }
        }
    }

    private func refreshZoomTarget() {
        guard zoomState.isVisible, let doc = document, let page = activePage else { return }
        activeZoomDrawing = store.loadDrawing(for: page)
        if let pdfName = doc.pdfFileName, let pdfIdx = page.pdfPageIndex {
            let pdfDoc = PDFPageBackgroundView.cachedDocument(for: store.pdfURL(for: pdfName))
            zoomState.pageSize = PageGeometry.logicalSize(for: pdfDoc?.page(at: pdfIdx))
        } else {
            zoomState.pageSize = PageGeometry.notebookSize
        }
    }

    private func switchDocument(to newDoc: NoteDocument) {
        withAnimation {
            showQuickSwitcher = false
        }
        if newDoc.id != documentId {
            onOpenDocument(newDoc.id)
        }
    }

    private func exportToPDF() {
        guard let doc = document, !isExporting else { return }
        isExporting = true
        Task { @MainActor in
            let url = PDFExportService.shared.exportDocumentToPDF(document: doc, store: store)
            isExporting = false
            if let url = url {
                exportedPDFURL = url
                showShareSheet = true
            }
        }
    }

}

// MARK: - Folio Continuous Page Canvas Card

struct FolioPageCanvasCard: View {
    let page: NotePage
    let doc: NoteDocument
    /// On-screen points per logical page point.
    let scale: CGFloat
    let isDark: Bool
    let showMargin: Bool
    let allowsFingerDrawing: Bool
    let showsToolPicker: Bool
    let snapsToShapes: Bool
    let isZoomTarget: Bool
    @ObservedObject var store: DocumentStore
    let canvasController: CanvasController
    @ObservedObject var zoomState: ZoomWindowState
    let onActivate: () -> Void
    let onDrawingSaved: (PKDrawing) -> Void

    @State private var pageDrawing: PKDrawing = PKDrawing()
    @State private var marginDrawing: PKDrawing = PKDrawing()
    @State private var hasLoaded: Bool = false

    private var pdfURL: URL? {
        doc.pdfFileName.map { store.pdfURL(for: $0) }
    }

    private var isPdfPage: Bool {
        page.pdfPageIndex != nil && pdfURL != nil
    }

    private var logicalSize: CGSize {
        guard isPdfPage, let url = pdfURL, let idx = page.pdfPageIndex else {
            return PageGeometry.notebookSize
        }
        let pdf = PDFPageBackgroundView.cachedDocument(for: url)
        return PageGeometry.logicalSize(for: pdf?.page(at: idx))
    }

    /// Paper shown behind notebook pages; dark mode uses charcoal paper.
    private var displayedPaper: PaperColor {
        isDark ? .dark : page.paperColor
    }

    /// PDF pages are always light, so their ink must render in light mode.
    private var pageIsDark: Bool {
        !isPdfPage && displayedPaper.isDark
    }

    var body: some View {
        let size = logicalSize
        let displaySize = CGSize(width: size.width * scale, height: size.height * scale)

        HStack(alignment: .top, spacing: 8) {
            // Main Page (Paper or PDF)
            ZStack(alignment: .topLeading) {
                // 1. Background
                if isPdfPage, let url = pdfURL, let pdfIdx = page.pdfPageIndex {
                    PDFPageBackgroundView(pdfURL: url, pageIndex: pdfIdx)
                } else {
                    PaperBackgroundView(
                        templateType: page.templateType,
                        paperColor: displayedPaper,
                        contentScale: scale
                    )
                }

                // 2. PencilKit drawing layer (logical coordinates, scaled to fit)
                PencilCanvasContainer(
                    drawing: $pageDrawing,
                    isPencilOnly: !allowsFingerDrawing,
                    controller: canvasController,
                    onDrawingChanged: { updated in
                        store.saveDrawing(updated, for: page)
                        onDrawingSaved(updated)
                    },
                    contentScale: scale,
                    interfaceStyle: pageIsDark ? .dark : .light,
                    showsToolPicker: showsToolPicker,
                    onBeginDrawing: onActivate,
                    snapsToShapes: snapsToShapes
                )

                // 3. Zoom Window target box (Mockup 1d), only on the page being written on
                if zoomState.isVisible && isZoomTarget {
                    TargetBoxOverlay(state: zoomState, isDark: isDark)
                        .frame(width: size.width, height: size.height)
                        .scaleEffect(scale, anchor: .topLeading)
                        .frame(width: displaySize.width, height: displaySize.height, alignment: .topLeading)
                }

                // 4. Page number stamp
                HStack(spacing: 4) {
                    Spacer()
                    if page.isBookmarked {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 11))
                            .foregroundColor(FolioTheme.accent(isDark: isDark))
                    }
                    Text("\(page.pageIndex + 1)")
                        .font(.system(size: 11, weight: .medium, design: .serif))
                        .foregroundColor(FolioTheme.textSecondary(isDark: pageIsDark).opacity(0.6))
                }
                .padding(.top, 10)
                .padding(.trailing, 14)
                .allowsHitTesting(false)
            }
            .frame(width: displaySize.width, height: displaySize.height)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(color: Color.black.opacity(isDark ? 0.4 : 0.12), radius: 8, x: 0, y: 3)

            // Writable side margin for PDFs (Mockup 1e)
            if showMargin && doc.type == .pdfDocument {
                let marginWidth = PageGeometry.marginLogicalWidth * scale
                ZStack(alignment: .topLeading) {
                    PaperBackgroundView(
                        templateType: .dotGrid,
                        paperColor: isDark ? .dark : .ivory,
                        contentScale: scale
                    )

                    Text("MARGIN NOTES")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1.0)
                        .foregroundColor(FolioTheme.accent(isDark: isDark).opacity(0.7))
                        .padding(10)
                        .allowsHitTesting(false)

                    PencilCanvasContainer(
                        drawing: $marginDrawing,
                        isPencilOnly: !allowsFingerDrawing,
                        controller: canvasController,
                        onDrawingChanged: { updated in
                            store.saveMarginDrawing(updated, for: page)
                        },
                        contentScale: scale,
                        interfaceStyle: isDark ? .dark : .light,
                        showsToolPicker: showsToolPicker,
                        onBeginDrawing: onActivate,
                        snapsToShapes: snapsToShapes
                    )
                }
                .frame(width: marginWidth, height: displaySize.height)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(FolioTheme.accent(isDark: isDark).opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .allowsHitTesting(false)
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            if !hasLoaded {
                pageDrawing = store.loadDrawing(for: page)
                marginDrawing = store.loadMarginDrawing(for: page)
                hasLoaded = true
            }
        }
        .onChange(of: store.drawingRevision(for: page.id)) {
            // Written elsewhere (e.g. Zoom Window) — pick up the new strokes.
            pageDrawing = store.loadDrawing(for: page)
        }
    }
}

// MARK: - Screen 1b Floating Toolbar Capsule

struct FolioFloatingToolbarCapsule: View {
    let isDark: Bool
    let zoomActive: Bool
    let snapActive: Bool
    let canEditPaper: Bool
    let isBookmarked: Bool
    let isPdf: Bool
    let marginVisible: Bool
    let fingerDrawing: Bool
    let paletteActive: Bool

    let onToggleZoom: () -> Void
    let onToggleSnap: () -> Void
    let onPaperSettings: () -> Void
    let onAddPage: () -> Void
    let onToggleBookmark: () -> Void
    let onUndo: () -> Void
    let onRedo: () -> Void
    let onToggleMargin: () -> Void
    let onToggleFingerDrawing: () -> Void
    let onTogglePalette: () -> Void
    let onToggleTheme: () -> Void
    let onEnterFocus: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            // Zoom Window (Handwriting Magnifier Dock)
            ToolbarIconButton(icon: "plus.magnifyingglass", isActive: zoomActive, isDark: isDark, label: "Zoom window", action: onToggleZoom)

            // Snap to shape: hold the pencil still at the end of a stroke
            ToolbarIconButton(icon: "square.on.circle", isActive: snapActive, isDark: isDark, label: snapActive ? "Turn off snap to shape" : "Snap to shape (hold pencil still for 2 seconds)", action: onToggleSnap)

            ToolbarDivider(isDark: isDark)

            // Page tools
            if canEditPaper {
                ToolbarIconButton(icon: "doc.text", isActive: false, isDark: isDark, label: "Paper template", action: onPaperSettings)
            }
            ToolbarIconButton(icon: "doc.badge.plus", isActive: false, isDark: isDark, label: "Add page after this one", action: onAddPage)
            ToolbarIconButton(icon: isBookmarked ? "bookmark.fill" : "bookmark", isActive: isBookmarked, isDark: isDark, label: "Bookmark page", action: onToggleBookmark)

            ToolbarDivider(isDark: isDark)

            // Undo & Redo
            ToolbarIconButton(icon: "arrow.uturn.backward", isActive: false, isDark: isDark, label: "Undo", action: onUndo)
            ToolbarIconButton(icon: "arrow.uturn.forward", isActive: false, isDark: isDark, label: "Redo", action: onRedo)

            ToolbarDivider(isDark: isDark)

            // Layout & input
            if isPdf {
                ToolbarIconButton(icon: "sidebar.right", isActive: marginVisible, isDark: isDark, label: marginVisible ? "Hide note margin" : "Show note margin", action: onToggleMargin)
            }
            ToolbarIconButton(icon: "applepencil", isActive: paletteActive, isDark: isDark, label: paletteActive ? "Hide tool palette" : "Show tool palette", action: onTogglePalette)
            ToolbarIconButton(icon: "arrow.up.left.and.arrow.down.right", isActive: false, isDark: isDark, label: "Focus mode", action: onEnterFocus)

            // Less-frequent settings
            Menu {
                Button(action: onToggleFingerDrawing) {
                    Label(fingerDrawing ? "Draw with Apple Pencil Only" : "Allow Drawing with Finger", systemImage: fingerDrawing ? "applepencil" : "hand.draw")
                }
                Button(action: onToggleTheme) {
                    Label(isDark ? "Light Mode" : "Dark Mode", systemImage: isDark ? "sun.max" : "moon")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundColor(fingerDrawing ? FolioTheme.accent(isDark: isDark) : FolioTheme.text(isDark: isDark))
                    .frame(width: 38, height: 38)
            }
            .accessibilityLabel("More options")
        }
        .padding(.horizontal, 8)
        .frame(height: 52)
        .background(isDark ? Color(hex: "#242323") : Color.white)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(FolioTheme.divider(isDark: isDark), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(isDark ? 0.35 : 0.09), radius: 8, x: 0, y: 3)
        .fixedSize()
    }
}

struct ToolbarIconButton: View {
    let icon: String
    let isActive: Bool
    let isDark: Bool
    var label: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(isActive ? FolioTheme.accent(isDark: isDark) : FolioTheme.text(isDark: isDark))
                .frame(width: 38, height: 38)
                .background(isActive ? FolioTheme.accent(isDark: isDark).opacity(0.14) : Color.clear)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isActive ? FolioTheme.accent(isDark: isDark) : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(label)
        .help(label)
    }
}

struct ToolbarDivider: View {
    let isDark: Bool
    var body: some View {
        Rectangle()
            .fill(FolioTheme.divider(isDark: isDark))
            .frame(width: 1, height: 24)
            .padding(.horizontal, 4)
    }
}

// MARK: - Screen 1c Quick Switcher Panel

struct FolioQuickSwitcherPanel: View {
    let currentDoc: NoteDocument
    @ObservedObject var store: DocumentStore
    let isDark: Bool
    let onClose: () -> Void
    let onSelectDoc: (NoteDocument) -> Void
    let onBackToLibrary: () -> Void

    private enum Filter: Int {
        case thisFolder, recent, favorites
    }

    @State private var filter: Filter = .thisFolder
    @State private var query: String = ""

    private var listedDocs: [NoteDocument] {
        // Typing searches every document ("Jump to any file").
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            return store.searchDocuments(matching: query)
        }
        switch filter {
        case .thisFolder: return store.documents(in: currentDoc.folderId)
        case .recent: return store.recentDocuments(limit: 20)
        case .favorites: return store.favoriteDocuments()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header Bar
            HStack(spacing: 8) {
                Button(action: onBackToLibrary) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Library")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(FolioTheme.accent(isDark: isDark))
                }

                Spacer()

                Text(store.folder(for: currentDoc.folderId)?.name ?? "Home")
                    .font(FolioTheme.serifHeading(size: 18, weight: .semibold))
                    .foregroundColor(FolioTheme.text(isDark: isDark))
                    .lineLimit(1)

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(FolioTheme.textSecondary(isDark: isDark))
                        .frame(width: 30, height: 30)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            // Search Input
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundColor(FolioTheme.textSecondary(isDark: isDark))
                TextField("Jump to any file", text: $query)
                    .font(.system(size: 13))
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(FolioTheme.textSecondary(isDark: isDark))
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isDark ? Color(hex: "#2c2b2b") : Color.white)
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(FolioTheme.divider(isDark: isDark), lineWidth: 1))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            // Segmented Control
            Picker("", selection: $filter) {
                Text("This folder").tag(Filter.thisFolder)
                Text("Recent").tag(Filter.recent)
                Text("Favorites").tag(Filter.favorites)
            }
            .pickerStyle(SegmentedPickerStyle())
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            .disabled(!query.isEmpty)

            Divider().background(FolioTheme.divider(isDark: isDark))

            // Document List
            ScrollView {
                VStack(spacing: 0) {
                    if listedDocs.isEmpty {
                        Text(query.isEmpty ? "Nothing here yet" : "No matches")
                            .font(.system(size: 13))
                            .foregroundColor(FolioTheme.textSecondary(isDark: isDark))
                            .padding(.vertical, 30)
                    }
                    ForEach(listedDocs) { doc in
                        let isCurrent = doc.id == currentDoc.id
                        Button {
                            onSelectDoc(doc)
                        } label: {
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(isDark ? Color(hex: "#2c2b2b") : Color(hex: "#f8f4f4"))
                                    .frame(width: 32, height: 42)
                                    .overlay(
                                        Image(systemName: doc.type == .pdfDocument ? "doc.richtext" : "pencil.line")
                                            .font(.system(size: 12))
                                            .foregroundColor(Color(hex: doc.coverColorHex))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 2)
                                            .stroke(FolioTheme.divider(isDark: isDark), lineWidth: 1)
                                    )

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(doc.title)
                                        .font(.system(size: 14, weight: isCurrent ? .semibold : .regular))
                                        .foregroundColor(isCurrent ? FolioTheme.accent(isDark: isDark) : FolioTheme.text(isDark: isDark))
                                        .lineLimit(1)

                                    Text("\(doc.type == .pdfDocument ? "PDF" : "Notebook") · \(doc.pageCount) pages")
                                        .font(.system(size: 11))
                                        .foregroundColor(FolioTheme.textSecondary(isDark: isDark))
                                }

                                Spacer()

                                if isCurrent {
                                    Text("Open")
                                        .font(.system(size: 10, weight: .bold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(FolioTheme.accent(isDark: isDark).opacity(0.16))
                                        .foregroundColor(FolioTheme.accent(isDark: isDark))
                                        .cornerRadius(4)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(isCurrent ? FolioTheme.accent(isDark: isDark).opacity(0.08) : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainButtonStyle())

                        Divider().background(FolioTheme.divider(isDark: isDark))
                    }
                }
            }

            // Bottom Action: New Notebook in this folder
            VStack {
                Button {
                    let newDoc = store.createNotebook(
                        title: "Untitled Notebook",
                        folderId: currentDoc.folderId,
                        template: .ruled,
                        paperColor: .ivory,
                        coverColorHex: "#b68235"
                    )
                    onSelectDoc(newDoc)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                        Text("New notebook in \(store.folder(for: currentDoc.folderId)?.name ?? "Home")")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(FolioTheme.accent(isDark: isDark))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(FolioTheme.accent(isDark: isDark).opacity(0.1))
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(FolioTheme.accent(isDark: isDark), lineWidth: 1))
                }
            }
            .padding(14)
            .background(FolioTheme.surface(isDark: isDark))
        }
        .frame(width: 390, height: 680)
        .background(FolioTheme.bg(isDark: isDark))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(FolioTheme.divider(isDark: isDark), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(isDark ? 0.45 : 0.16), radius: 18, x: 4, y: 8)
    }
}
