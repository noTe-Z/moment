import Foundation
import AVFoundation
import SwiftUI
import UIKit

@MainActor
final class TextEditorRecorderViewModel: ObservableObject {
    enum Mode: Equatable {
        case idle
        case recording
        case uploading
        case transcribing
        case failed
    }
    
    enum RecorderError: LocalizedError, Identifiable {
        case microphoneDenied
        case recordingInitializationFailed(String)
        case noActiveRecording
        case transcriptionFailed(String)
        case missingAPIKey
        case unknown(String)
        
        var id: String {
            localizedDescription
        }
        
        var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                return "请在系统设置中开启麦克风权限。"
            case .recordingInitializationFailed(let message):
                return "录音启动失败：\(message)"
            case .noActiveRecording:
                return "当前没有正在进行的录音。"
            case .transcriptionFailed(let message):
                return "转写失败：\(message)"
            case .missingAPIKey:
                return "未找到 AssemblyAI API Key，请在 Xcode Scheme 中设置 ASSEMBLYAI_API_KEY。"
            case .unknown(let message):
                return "出现未知错误：\(message)"
            }
        }
    }
    
    @Published private(set) var mode: Mode = .idle
    @Published private(set) var statusMessage: String?
    @Published private(set) var elapsedDisplay: String = "00:00"
    @Published var presentableError: RecorderError?
    
    private let recordingStore = RecordingStore()
    private let transcriptionService = AssemblyAITranscriptionService()
    
    private var audioRecorder: AVAudioRecorder?
    private var recordingStartDate: Date?
    private var timer: Timer?
    private var fileURL: URL?
    
    func startRecording() async throws {
        guard mode != .recording else { return }
        
        guard await ensurePermission() else {
            presentableError = .microphoneDenied
            throw RecorderError.microphoneDenied
        }
        
        presentableError = nil
        
        do {
            try configureAudioSessionActive()
            let now = Date()
            let url = recordingStore.prepareFileURL(for: now)
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ])
            
            recorder.record()
            audioRecorder = recorder
            fileURL = url
            recordingStartDate = now
            elapsedDisplay = "00:00"
            mode = .recording
            statusMessage = "录音中…"
            startTimer()
            HapticFeedback.trigger(style: .light)
        } catch {
            resetSession()
            let message = error.localizedDescription
            let recorderError = RecorderError.recordingInitializationFailed(message)
            presentableError = recorderError
            throw recorderError
        }
    }
    
    func stopRecordingAndTranscribe() async throws -> String {
        guard mode == .recording else {
            let error = RecorderError.noActiveRecording
            presentableError = error
            throw error
        }
        
        audioRecorder?.stop()
        audioRecorder = nil
        stopTimer()
        mode = .uploading
        statusMessage = "上传中…"
        
        guard let fileURL else {
            resetState()
            let error = RecorderError.recordingInitializationFailed("录音文件缺失。")
            presentableError = error
            throw error
        }
        
        defer { resetSession() }
        
        do {
            let transcript = try await transcriptionService.transcribeAudioFile(at: fileURL) { [weak self] stage in
                guard let self else { return }
                switch stage {
                case .uploading:
                    self.mode = .uploading
                    self.statusMessage = "上传中…"
                case .transcribing:
                    self.mode = .transcribing
                    self.statusMessage = "转写中…"
                case .completed:
                    break
                }
            }
            
            cleanupRecordingFile()
            resetState()
            return transcript
        } catch let serviceError as AssemblyAITranscriptionService.TranscriptionError {
            cleanupRecordingFile()
            mode = .failed
            let recorderError: RecorderError
            switch serviceError {
            case .missingAPIKey:
                recorderError = .missingAPIKey
            case .uploadFailed(let message),
                 .transcriptionFailed(let message),
                 .invalidResponse(let message),
                 .pollingTimeout(let message):
                recorderError = .transcriptionFailed(message)
            case .unknown(let message):
                recorderError = .unknown(message)
            }
            statusMessage = "转写失败"
            presentableError = recorderError
            throw recorderError
        } catch {
            cleanupRecordingFile()
            mode = .failed
            statusMessage = "转写失败"
            let recorderError = RecorderError.unknown(error.localizedDescription)
            presentableError = recorderError
            throw recorderError
        }
    }
    
    func cancelActiveRecording() {
        audioRecorder?.stop()
        cleanupRecordingFile()
        resetSession()
        resetState()
    }
    
    private func startTimer() {
        stopTimer()
        guard let startDate = recordingStartDate else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self else { return }
            let elapsed = Date().timeIntervalSince(startDate)
            elapsedDisplay = TimeFormatter.display(for: elapsed)
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    private func resetState() {
        mode = .idle
        statusMessage = nil
        elapsedDisplay = "00:00"
        recordingStartDate = nil
        fileURL = nil
        presentableError = nil
    }
    
    private func cleanupRecordingFile() {
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
            self.fileURL = nil
        }
    }
    
    private func configureAudioSessionActive() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
        try session.setActive(true, options: [])
    }
    
    private func resetSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            // Ignored
        }
    }
    
    private func ensurePermission() async -> Bool {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                session.requestRecordPermission { allowed in
                    continuation.resume(returning: allowed)
                }
            }
        @unknown default:
            return false
        }
    }
}

private enum HapticFeedback {
    enum Style {
        case light
        
        var impactStyle: UIImpactFeedbackGenerator.FeedbackStyle {
            switch self {
            case .light:
                return .light
            }
        }
        
        var intensity: CGFloat {
            switch self {
            case .light:
                return 0.8
            }
        }
    }
    
    static func trigger(style: Style) {
        let generator = UIImpactFeedbackGenerator(style: style.impactStyle)
        generator.impactOccurred(intensity: style.intensity)
    }
}


