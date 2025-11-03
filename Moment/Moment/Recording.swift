import Foundation
import SwiftData

@Model
final class Recording {
    @Attribute(.unique) var id: UUID
    var timestamp: Date
    var duration: TimeInterval
    var fileName: String

    init(id: UUID = UUID(), timestamp: Date, duration: TimeInterval, fileName: String) {
        self.id = id
        self.timestamp = timestamp
        self.duration = duration
        self.fileName = fileName
    }
}

extension Recording {
    var fileURL: URL {
        RecordingStore.recordingsDirectory.appendingPathComponent(fileName)
    }
}
