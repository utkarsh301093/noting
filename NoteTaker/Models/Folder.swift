import Foundation

/// Represents a folder or subfolder in the hierarchical organization system.
public struct Folder: Identifiable, Codable, Equatable, Hashable {
    public let id: UUID
    public var name: String
    public var parentId: UUID?
    public var colorHex: String
    public var iconName: String
    public var createdDate: Date
    public var updatedDate: Date
    
    public init(
        id: UUID = UUID(),
        name: String,
        parentId: UUID? = nil,
        colorHex: String = "#4E2A84",
        iconName: String = "folder.fill",
        createdDate: Date = Date(),
        updatedDate: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.parentId = parentId
        self.colorHex = colorHex
        self.iconName = iconName
        self.createdDate = createdDate
        self.updatedDate = updatedDate
    }
}
