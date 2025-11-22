import Foundation
import SwiftData

@Model
final class Recording {
    @Attribute(.unique) var id: UUID
    var timestamp: Date
    var duration: TimeInterval
    var fileName: String
    var title: String?
    var transcriptText: String?
    var polishedTranscriptText: String?
    var transcriptUpdatedAt: Date?
    var transcriptionErrorMessage: String?
    var transcriptionRequestedAt: Date?
    var transcriptionRetryCount: Int = 0
    var transcriptionLastAttemptAt: Date?
    var transcriptionNextRetryAt: Date?
    var transcriptionStatusRawValue: String = TranscriptionStatus.idle.rawValue

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
        if let polished = polishedTranscriptText?.trimmingCharacters(in: .whitespacesAndNewlines), !polished.isEmpty {
            return polished
        }
        guard let raw = transcriptText?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw
    }
    
    var needsAutomaticTranscription: Bool {
        guard !hasTranscript else { return false }
        switch transcriptionStatus {
        case .completed:
            return false
        case .processing:
            return false
        default:
            return true
        }
    }
    
    var isWaitingForScheduledRetry: Bool {
        guard let nextRetryAt = transcriptionNextRetryAt else { return false }
        return nextRetryAt > Date()
    }
    
    var canAttemptTranscriptionImmediately: Bool {
        guard needsAutomaticTranscription else { return false }
        if isWaitingForScheduledRetry {
            return false
        }
        return true
    }
    
    var canManualRetryTranscription: Bool {
        !isWaitingForScheduledRetry && transcriptionStatus != .processing
    }
    
    func queuedStatusDescription(referenceDate: Date = Date()) -> String? {
        guard transcriptionStatus == .queued else { return nil }
        if let nextRetryAt = transcriptionNextRetryAt, nextRetryAt > referenceDate {
            let relative = Recording.relativeFormatter.localizedString(for: nextRetryAt, relativeTo: referenceDate)
            return "达到并发上限，\(relative) 后自动重试"
        }
        return "排队等待转写"
    }
    
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}
