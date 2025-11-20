import Foundation
import SwiftData

@Model
final class TextNote {
    @Attribute(.unique) var id: UUID
    var title: String
    var content: String
    var createdAt: Date
    var updatedAt: Date
    
    @Attribute(originalName: "recordingID")
    private var legacyRecordingID: UUID?
    
    // 关联的录音 ID 列表
    var recordingIDs: [UUID] = []
    
    init(
        id: UUID = UUID(),
        title: String,
        content: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        recordingIDs: [UUID] = [],
        recordingID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.recordingIDs = recordingIDs
        self.legacyRecordingID = recordingID
        migrateLegacyRecordingIfNeeded()
    }
}

extension TextNote {
    /// 所有关联的录音 ID，包含历史单个 ID
    var allRecordingIDs: [UUID] {
        if recordingIDs.isEmpty, let legacyRecordingID {
            return [legacyRecordingID]
        }
        return recordingIDs
    }
    
    /// 将新的录音 ID 添加到笔记中，避免重复
    func appendRecordingID(_ id: UUID) {
        migrateLegacyRecordingIfNeeded()
        if !recordingIDs.contains(id) {
            recordingIDs.append(id)
        }
    }
    
    /// 批量覆盖录音 ID，自动去重
    func setRecordingIDs(_ ids: [UUID]) {
        migrateLegacyRecordingIfNeeded()
        var unique: [UUID] = []
        for id in ids where !unique.contains(id) {
            unique.append(id)
        }
        recordingIDs = unique
    }
    
    /// 如果存在 legacy 字段则迁移到 recordingIDs
    func migrateLegacyRecordingIfNeeded() {
        if recordingIDs.isEmpty, let legacyRecordingID {
            recordingIDs = [legacyRecordingID]
            self.legacyRecordingID = nil
        } else if let legacyRecordingID {
            if !recordingIDs.contains(legacyRecordingID) {
                recordingIDs.insert(legacyRecordingID, at: 0)
            }
            self.legacyRecordingID = nil
        }
    }
}

