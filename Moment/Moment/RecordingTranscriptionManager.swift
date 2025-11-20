import Foundation
import SwiftData

@MainActor
final class RecordingTranscriptionManager: ObservableObject {
    static let shared = RecordingTranscriptionManager()
    
    private let transcriptionService = AssemblyAITranscriptionService()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    
    private init() {}
    
    func ensureTranscripts(for recordings: [Recording], in context: ModelContext) {
        recordings.forEach { ensureTranscript(for: $0, in: context) }
    }
    
    func ensureTranscript(for recording: Recording, in context: ModelContext, force: Bool = false) {
        if tasks[recording.id] != nil { return }
        if !force && !recording.needsAutomaticTranscription { return }
        guard FileManager.default.fileExists(atPath: recording.fileURL.path) else {
            recording.transcriptionStatus = .failed
            recording.transcriptionErrorMessage = "录音文件不存在，无法转写。"
            try? context.save()
            return
        }
        
        startTranscription(for: recording, in: context)
    }
    
    func retryTranscription(for recording: Recording, in context: ModelContext) {
        recording.transcriptionStatus = .queued
        recording.transcriptionErrorMessage = nil
        try? context.save()
        ensureTranscript(for: recording, in: context, force: true)
    }
    
    private func startTranscription(for recording: Recording, in context: ModelContext) {
        recording.transcriptionStatus = .processing
        recording.transcriptionErrorMessage = nil
        recording.transcriptionRequestedAt = Date()
        try? context.save()
        
        let recordingID = recording.id
        let fileURL = recording.fileURL
        
        tasks[recordingID] = Task(priority: .background) { [weak self] in
            guard let self else { return }
            defer { self.tasks[recordingID] = nil }
            
            do {
                let transcript = try await self.transcriptionService.transcribeAudioFile(at: fileURL)
                try Task.checkCancellation()
                self.handleSuccess(transcript: transcript, recordingID: recordingID, context: context)
            } catch is CancellationError {
                self.handleCancellation(recordingID: recordingID, context: context)
            } catch let error as AssemblyAITranscriptionService.TranscriptionError {
                self.handleFailure(recordingID: recordingID, context: context, message: error.errorDescription ?? error.localizedDescription)
            } catch {
                self.handleFailure(recordingID: recordingID, context: context, message: error.localizedDescription)
            }
        }
    }
    
    private func handleSuccess(transcript: String, recordingID: UUID, context: ModelContext) {
        guard let recording = fetchRecording(with: recordingID, in: context) else { return }
        recording.transcriptText = transcript
        recording.transcriptUpdatedAt = Date()
        recording.transcriptionStatus = .completed
        recording.transcriptionErrorMessage = nil
        try? context.save()
    }
    
    private func handleFailure(recordingID: UUID, context: ModelContext, message: String) {
        guard let recording = fetchRecording(with: recordingID, in: context) else { return }
        recording.transcriptionStatus = .failed
        recording.transcriptionErrorMessage = message
        try? context.save()
    }
    
    private func handleCancellation(recordingID: UUID, context: ModelContext) {
        guard let recording = fetchRecording(with: recordingID, in: context) else { return }
        if recording.transcriptionStatus == .processing {
            recording.transcriptionStatus = .idle
        }
        try? context.save()
    }
    
    private func fetchRecording(with id: UUID, in context: ModelContext) -> Recording? {
        var descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate { $0.id == id },
            sortBy: []
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}

