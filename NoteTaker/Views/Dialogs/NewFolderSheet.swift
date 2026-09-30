import SwiftUI

/// Modal sheet to create a new folder or nested subfolder for a class or subject.
public struct NewFolderSheet: View {
    @ObservedObject public var store: DocumentStore
    public let defaultParentId: UUID?
    
    @State private var folderName: String = ""
    @State private var selectedParentId: UUID?
    @State private var selectedColorHex: String = "#4E2A84"
    @State private var selectedIcon: String = "folder.fill"
    
    @Environment(\.dismiss) private var dismiss
    
    let availableIcons = [
        "folder.fill", "books.vertical.fill", "graduationcap.fill",
        "chart.line.uptrend.xyaxis", "target", "function",
        "person.3.fill", "briefcase.fill", "doc.text.fill", "archivebox.fill"
    ]
    
    public init(store: DocumentStore, defaultParentId: UUID? = nil) {
        self.store = store
        self.defaultParentId = defaultParentId
        self._selectedParentId = State(initialValue: defaultParentId)
    }
    
    public var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Folder Details")) {
                    TextField("Folder or Class Name (e.g. FINC 430)", text: $folderName)
                        .autocorrectionDisabled()
                    
                    Picker("Location / Parent Folder", selection: $selectedParentId) {
                        Text("Root (Top Level)").tag(Optional<UUID>(nil))
                        ForEach(store.folderTree()) { entry in
                            Text(String(repeating: "    ", count: entry.depth) + entry.folder.name)
                                .tag(Optional<UUID>(entry.folder.id))
                        }
                    }
                }
                
                Section(header: Text("Folder Color")) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 12) {
                        ForEach(BrandTheme.availableFolderColors, id: \.hex) { item in
                            Circle()
                                .fill(item.color)
                                .frame(width: 34, height: 34)
                                .overlay(
                                    Circle()
                                        .stroke(Color.primary, lineWidth: selectedColorHex == item.hex ? 3 : 0)
                                )
                                .onTapGesture {
                                    selectedColorHex = item.hex
                                }
                        }
                    }
                    .padding(.vertical, 6)
                }
                
                Section(header: Text("Folder Icon")) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 14) {
                        ForEach(availableIcons, id: \.self) { icon in
                            Image(systemName: icon)
                                .font(.system(size: 22))
                                .frame(width: 44, height: 44)
                                .background(selectedIcon == icon ? BrandTheme.brandPurple.opacity(0.15) : Color.clear)
                                .foregroundColor(selectedIcon == icon ? BrandTheme.brandPurple : .secondary)
                                .cornerRadius(8)
                                .onTapGesture {
                                    selectedIcon = icon
                                }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .navigationTitle("New Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        _ = store.createFolder(
                            name: folderName.trimmingCharacters(in: .whitespacesAndNewlines),
                            parentId: selectedParentId,
                            colorHex: selectedColorHex,
                            iconName: selectedIcon
                        )
                        dismiss()
                    }
                    .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .fontWeight(.semibold)
                    .foregroundColor(BrandTheme.brandPurple)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
