import Foundation
import SwiftData

@Model
final class Recording {
    @Attribute(.unique) var id: UUID
    var timestamp: Date
    var duration: TimeInterval
    var fileName: String
    var transcriptText: String?
    var transcriptUpdatedAt: Date?
    var transcriptionErrorMessage: String?
    var transcriptionRequestedAt: Date?
    private var transcriptionStatusRawValue: String = TranscriptionStatus.idle.rawValue

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
    
    enum TranscriptionStatus: String, Codable {
        case idle
        case queued
        case processing
        case completed
        case failed
    }
    
    var transcriptionStatus: TranscriptionStatus {
        get { TranscriptionStatus(rawValue: transcriptionStatusRawValue) ?? .idle }
        set { transcriptionStatusRawValue = newValue.rawValue }
    }
    
    var hasTranscript: Bool {
        transcriptText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
    
    var normalizedTranscriptText: String? {
        guard let raw = transcriptText?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw
    }
    
    var needsAutomaticTranscription: Bool {
        switch transcriptionStatus {
        case .idle, .queued:
            return !hasTranscript
        case .failed:
            // allow retry only when there is no successful transcript
            return !hasTranscript
        case .processing:
            return false
        case .completed:
            return !hasTranscript
        }
    }
}
