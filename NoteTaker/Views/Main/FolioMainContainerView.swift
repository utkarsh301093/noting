import SwiftUI

/// Main container coordinating between Folio's two distinct modes:
/// 1. Library Mode: The Classical editorial file & folder browser (Screen 1a)
/// 2. Immersive Notebook Mode: Full-bleed zero-chrome writing canvas (Screen 1b-1e)
public struct FolioMainContainerView: View {
    @StateObject private var theme = ThemeManager.shared
    @State private var activeDocumentId: UUID? = nil
    
    public init() {}
    
    public var body: some View {
        ZStack {
            if let docId = activeDocumentId {
                FolioImmersiveEditorView(
                    documentId: docId,
                    onBackToLibrary: {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            activeDocumentId = nil
                        }
                    },
                    onOpenDocument: { newId in
                        activeDocumentId = newId
                    }
                )
                .id(docId) // fresh editor state (scroll position, zoom target) per document
                .transition(.opacity)
            } else {
                FolioLibraryView(activeDocumentId: $activeDocumentId)
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(theme.isDarkMode ? .dark : .light)
    }
}
