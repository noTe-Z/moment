import Foundation
import SwiftData

@MainActor
final class RecordingTranscriptionManager: ObservableObject {
    static let shared = RecordingTranscriptionManager()
    
    private struct QueuedJob: Equatable {
        let id: UUID
        let force: Bool
    }
    
    private enum Constants {
        static let maxConcurrentJobs = 2
        static let baseRetryDelay: TimeInterval = 30
        static let maxRetryDelay: TimeInterval = 15 * 60
    }
    
    private let transcriptionService = AssemblyAITranscriptionService()
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingJobs: [QueuedJob] = []
    private var scheduledWakeTask: Task<Void, Never>?
    
    private init() {}
    
    func ensureTranscripts(for recordings: [Recording], in context: ModelContext) {
        recordings.forEach { ensureTranscript(for: $0, in: context) }
    }
    
    func ensureTranscript(for recording: Recording, in context: ModelContext, force: Bool = false) {
        guard shouldEnqueue(recording: recording, force: force) else { return }
        enqueue(recordingID: recording.id, force: force, in: context)
    }
    
    func retryTranscription(for recording: Recording, in context: ModelContext) {
        recording.transcriptionStatus = .queued
        recording.transcriptionErrorMessage = nil
        recording.transcriptionRetryCount = 0
        recording.transcriptionNextRetryAt = nil
        try? context.save()
        enqueue(recordingID: recording.id, force: true, in: context)
    }
    
    func resumePendingTranscriptions(in context: ModelContext) {
        let queuedRawValue = Recording.TranscriptionStatus.queued.rawValue
        let processingRawValue = Recording.TranscriptionStatus.processing.rawValue
        
        let descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate {
                $0.transcriptText == nil &&
                ($0.transcriptionStatusRawValue == queuedRawValue ||
                 $0.transcriptionStatusRawValue == processingRawValue)
            }
        )
        
        if let records = try? context.fetch(descriptor) {
            records.forEach { recording in
                if recording.transcriptionStatus == .processing {
                    recording.transcriptionStatus = .queued
                    recording.transcriptionErrorMessage = nil
                }
                ensureTranscript(for: recording, in: context)
            }
        }
    }
}

// MARK: - Queue Management

@MainActor
private extension RecordingTranscriptionManager {
    func shouldEnqueue(recording: Recording, force: Bool) -> Bool {
        if recording.hasTranscript && !force { return false }
        if recording.transcriptionStatus == .completed && !force { return false }
        if activeTasks.keys.contains(recording.id) { return false }
        if pendingJobs.contains(where: { $0.id == recording.id }) { return false }
        if !force && recording.isWaitingForScheduledRetry { return false }
        return recording.needsAutomaticTranscription || force
    }
    
    func enqueue(recordingID: UUID, force: Bool, in context: ModelContext) {
        pendingJobs.append(QueuedJob(id: recordingID, force: force))
        updateRecordingQueuedState(recordingID: recordingID, in: context)
        processQueueIfNeeded(in: context)
    }
    
    func updateRecordingQueuedState(recordingID: UUID, in context: ModelContext) {
        guard let recording = fetchRecording(with: recordingID, in: context) else { return }
        if recording.transcriptionStatus != .processing {
            recording.transcriptionStatus = .queued
            recording.transcriptionRequestedAt = recording.transcriptionRequestedAt ?? Date()
        }
        try? context.save()
    }
    
    func processQueueIfNeeded(in context: ModelContext) {
        cleanupWakeTaskIfNeeded()
        var earliestFutureDate: Date?
        var index = 0
        
        while activeTasks.count < Constants.maxConcurrentJobs && index < pendingJobs.count {
            let job = pendingJobs[index]
            guard let recording = fetchRecording(with: job.id, in: context) else {
                pendingJobs.remove(at: index)
                continue
            }
            
            if !job.force,
               let nextRetry = recording.transcriptionNextRetryAt,
               nextRetry > Date() {
                earliestFutureDate = min(earliestFutureDate ?? nextRetry, nextRetry)
                index += 1
                continue
            }
            
            if !recording.needsAutomaticTranscription && !job.force {
                pendingJobs.remove(at: index)
                continue
            }
            
            pendingJobs.remove(at: index)
            startTranscription(for: recording, in: context)
        }
        
        if activeTasks.count < Constants.maxConcurrentJobs,
           let wakeDate = earliestFutureDate {
            scheduleWake(at: wakeDate, context: context)
        }
    }
    
    func scheduleWake(at date: Date, context: ModelContext) {
        let delay = max(0, date.timeIntervalSinceNow)
        scheduledWakeTask?.cancel()
        scheduledWakeTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await MainActor.run {
                self.scheduledWakeTask = nil
                self.processQueueIfNeeded(in: context)
            }
        }
    }
    
    func cleanupWakeTaskIfNeeded() {
        if scheduledWakeTask?.isCancelled == true {
            scheduledWakeTask = nil
        }
    }
}

// MARK: - Transcription Lifecycle

@MainActor
private extension RecordingTranscriptionManager {
    func startTranscription(for recording: Recording, in context: ModelContext) {
        guard FileManager.default.fileExists(atPath: recording.fileURL.path) else {
            recording.transcriptionStatus = .failed
            recording.transcriptionErrorMessage = "录音文件不存在，无法转写。"
            recording.transcriptionNextRetryAt = nil
            try? context.save()
            return
        }
        
        recording.transcriptionStatus = .processing
        recording.transcriptionErrorMessage = nil
        recording.transcriptionRequestedAt = recording.transcriptionRequestedAt ?? Date()
        recording.transcriptionLastAttemptAt = Date()
        recording.transcriptionNextRetryAt = nil
        try? context.save()
        
        let recordingID = recording.id
        let fileURL = recording.fileURL
        
        activeTasks[recordingID] = Task(priority: .background) { [weak self] in
            guard let self else { return }
            do {
                let transcript = try await self.transcriptionService.transcribeAudioFile(at: fileURL)
                try Task.checkCancellation()
                await self.handleSuccess(transcript: transcript, recordingID: recordingID, context: context)
            } catch is CancellationError {
                await self.handleCancellation(recordingID: recordingID, context: context)
            } catch let error as AssemblyAITranscriptionService.TranscriptionError {
                await self.handleError(error, recordingID: recordingID, context: context)
            } catch {
                await self.handleFailure(recordingID: recordingID, context: context, message: error.localizedDescription)
            }
            
            await MainActor.run {
                self.activeTasks[recordingID] = nil
                self.processQueueIfNeeded(in: context)
            }
        }
    }
    
    func handleSuccess(transcript: String, recordingID: UUID, context: ModelContext) {
        guard let recording = fetchRecording(with: recordingID, in: context) else { return }
        recording.transcriptText = transcript
        recording.transcriptUpdatedAt = Date()
        recording.transcriptionStatus = .completed
        recording.transcriptionErrorMessage = nil
        recording.transcriptionRetryCount = 0
        recording.transcriptionNextRetryAt = nil
        try? context.save()
    }
    
    func handleError(_ error: AssemblyAITranscriptionService.TranscriptionError, recordingID: UUID, context: ModelContext) {
        let message = error.errorDescription ?? error.localizedDescription
        if isConcurrencyLimit(message) {
            handleThrottle(recordingID: recordingID, context: context)
        } else {
            handleFailure(recordingID: recordingID, context: context, message: message)
        }
    }
    
    func handleThrottle(recordingID: UUID, context: ModelContext) {
        guard let recording = fetchRecording(with: recordingID, in: context) else { return }
        let retries = min(recording.transcriptionRetryCount + 1, 8)
        recording.transcriptionRetryCount = retries
        let delay = min(Constants.baseRetryDelay * pow(2, Double(retries - 1)), Constants.maxRetryDelay)
        let nextRetry = Date().addingTimeInterval(delay)
        recording.transcriptionStatus = .queued
        recording.transcriptionErrorMessage = "已到达并发上限，将在 \(Int(delay)) 秒后自动重试。"
        recording.transcriptionNextRetryAt = nextRetry
        try? context.save()
        
        enqueue(recordingID: recordingID, force: false, in: context)
    }
    
    func handleFailure(recordingID: UUID, context: ModelContext, message: String) {
        guard let recording = fetchRecording(with: recordingID, in: context) else { return }
        recording.transcriptionStatus = .failed
        recording.transcriptionErrorMessage = message
        recording.transcriptionNextRetryAt = nil
        try? context.save()
    }
    
    func handleCancellation(recordingID: UUID, context: ModelContext) {
        guard let recording = fetchRecording(with: recordingID, in: context) else { return }
        if recording.transcriptionStatus == .processing {
            recording.transcriptionStatus = .idle
        }
        try? context.save()
    }
    
    func fetchRecording(with id: UUID, in context: ModelContext) -> Recording? {
        var descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate { $0.id == id },
            sortBy: []
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
    
    func isConcurrencyLimit(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased.contains("concurr") ||
            lowercased.contains("rate limit") ||
            lowercased.contains("429")
    }
}

