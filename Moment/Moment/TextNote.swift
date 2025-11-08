import Foundation
import SwiftData

@Model
final class TextNote {
    @Attribute(.unique) var id: UUID
    var title: String
    var content: String
    var createdAt: Date
    var updatedAt: Date
    
    // 关联的录音ID（可选）
    var recordingID: UUID?
    
    init(id: UUID = UUID(), title: String, content: String, createdAt: Date = Date(), updatedAt: Date = Date(), recordingID: UUID? = nil) {
        self.id = id
        self.title = title
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.recordingID = recordingID
    }
}

