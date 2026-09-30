import SwiftUI

/// Modal sheet to create a fresh blank notebook with customized paper templates and covers.
public struct NewNotebookSheet: View {
    @ObservedObject public var store: DocumentStore
    public let defaultFolderId: UUID?
    public var onCreated: ((NoteDocument) -> Void)?
    
    @State private var title: String = ""
    @State private var selectedFolderId: UUID?
    @State private var selectedTemplate: PaperTemplateType = .ruled
    @State private var selectedPaperColor: PaperColor = .ivory
    @State private var selectedCoverColorHex: String = "#4E2A84"
    
    @Environment(\.dismiss) private var dismiss
    
    public init(
        store: DocumentStore,
        defaultFolderId: UUID? = nil,
        onCreated: ((NoteDocument) -> Void)? = nil
    ) {
        self.store = store
        self.defaultFolderId = defaultFolderId
        self.onCreated = onCreated
        self._selectedFolderId = State(initialValue: defaultFolderId)
    }
    
    public var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Notebook Title & Location")) {
                    TextField("Notebook Title (e.g. Week 1 - Macroeconomics)", text: $title)
                        .autocorrectionDisabled()
                    
                    Picker("Folder / Subject", selection: $selectedFolderId) {
                        Text("Root (No Folder)").tag(Optional<UUID>(nil))
                        ForEach(store.folderTree()) { entry in
                            Text(String(repeating: "    ", count: entry.depth) + entry.folder.name)
                                .tag(Optional<UUID>(entry.folder.id))
                        }
                    }
                }
                
                Section(header: Text("Notebook Cover Color")) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 12) {
                        ForEach(BrandTheme.availableFolderColors, id: \.hex) { item in
                            Circle()
                                .fill(item.color)
                                .frame(width: 34, height: 34)
                                .overlay(
                                    Circle()
                                        .stroke(Color.primary, lineWidth: selectedCoverColorHex == item.hex ? 3 : 0)
                                )
                                .onTapGesture {
                                    selectedCoverColorHex = item.hex
                                }
                        }
                    }
                    .padding(.vertical, 4)
                }
                
                Section(header: Text("Default Paper Layout")) {
                    Picker("Template", selection: $selectedTemplate) {
                        ForEach(PaperTemplateType.allCases) { template in
                            Label(template.rawValue, systemImage: template.iconName).tag(template)
                        }
                    }
                    
                    Picker("Paper Color Tone", selection: $selectedPaperColor) {
                        ForEach(PaperColor.allCases) { color in
                            Text(color.rawValue).tag(color)
                        }
                    }
                }
                
                // Visual Preview Card
                Section(header: Text("Preview")) {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color(hex: selectedCoverColorHex))
                                    .frame(width: 140, height: 180)
                                    .shadow(color: Color.black.opacity(0.15), radius: 6, x: 2, y: 3)
                                
                                // Binding strip
                                Rectangle()
                                    .fill(Color(hex: selectedCoverColorHex).opacity(0.8))
                                    .frame(width: 12, height: 180)
                                
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(title.isEmpty ? "Untitled Notebook" : title)
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundColor(.white)
                                        .lineLimit(3)
                                    Spacer()
                                    Text(selectedTemplate.rawValue)
                                        .font(.system(size: 10, weight: .semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(Color.white.opacity(0.2))
                                        .foregroundColor(.white)
                                        .cornerRadius(4)
                                }
                                .padding(12)
                                .frame(width: 140, height: 180)
                            }
                            
                            Text("Page 1: \(selectedTemplate.rawValue) (\(selectedPaperColor.rawValue))")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle("New Notebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let newDoc = store.createNotebook(
                            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                            folderId: selectedFolderId,
                            template: selectedTemplate,
                            paperColor: selectedPaperColor,
                            coverColorHex: selectedCoverColorHex
                        )
                        onCreated?(newDoc)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundColor(BrandTheme.brandPurple)
                }
            }
        }
    }
}
