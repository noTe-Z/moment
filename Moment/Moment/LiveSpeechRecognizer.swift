import Foundation
import AVFoundation
import Speech

final class LiveSpeechRecognizer: NSObject {
    enum RecognizerError: LocalizedError {
        case unsupportedLocale
        case speechPermissionDenied
        case microphonePermissionDenied
        case audioSessionFailed(String)
        case recognitionFailed(String)
        
        var errorDescription: String? {
            switch self {
            case .unsupportedLocale:
                return "当前设备不支持所选语言的语音识别。"
            case .speechPermissionDenied:
                return "请在系统设置中允许语音识别权限。"
            case .microphonePermissionDenied:
                return "请在系统设置中允许麦克风权限以继续练习。"
            case .audioSessionFailed(let message),
                 .recognitionFailed(let message):
                return message
            }
        }
    }
    
    var onTranscription: ((String, Bool) -> Void)?
    var onError: ((Error) -> Void)?
    
    private let localeIdentifier: String
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechRecognizer: SFSpeechRecognizer?
    
    init(localeIdentifier: String) {
        self.localeIdentifier = localeIdentifier
        super.init()
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
    }
    
    func start() async throws {
        guard recognitionTask == nil else { return }
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            throw RecognizerError.unsupportedLocale
        }
        
        try await ensurePermissions()
        try configureAudioSession()
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest?.shouldReportPartialResults = true
        
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }
        
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            throw RecognizerError.audioSessionFailed("音频引擎启动失败：\(error.localizedDescription)")
        }
        
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest!) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    self.onTranscription?(text, result.isFinal)
                }
                if result.isFinal {
                    self.recognitionRequest?.endAudio()
                }
            } else if let error {
                self.stop()
                DispatchQueue.main.async {
                    self.onError?(RecognizerError.recognitionFailed(error.localizedDescription))
                }
            }
        }
    }
    
    func stop() {
        recognitionTask?.cancel()
        recognitionTask = nil
        
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
    
    private func ensurePermissions() async throws {
        try await requestSpeechPermission()
        try await requestMicrophonePermission()
    }
    
    private func requestSpeechPermission() async throws {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { authorizationStatus in
                continuation.resume(returning: authorizationStatus)
            }
        }
        
        switch status {
        case .authorized:
            return
        case .denied, .restricted:
            throw RecognizerError.speechPermissionDenied
        case .notDetermined:
            throw RecognizerError.speechPermissionDenied
        @unknown default:
            throw RecognizerError.speechPermissionDenied
        }
    }
    
    private func requestMicrophonePermission() async throws {
        if #available(iOS 17, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                return
            case .denied:
                throw RecognizerError.microphonePermissionDenied
            case .undetermined:
                let granted = await withCheckedContinuation { continuation in
                    AVAudioApplication.requestRecordPermission { allowed in
                        continuation.resume(returning: allowed)
                    }
                }
                guard granted else {
                    throw RecognizerError.microphonePermissionDenied
                }
            @unknown default:
                throw RecognizerError.microphonePermissionDenied
            }
        } else {
            let session = AVAudioSession.sharedInstance()
            switch session.recordPermission {
            case .granted:
                return
            case .denied:
                throw RecognizerError.microphonePermissionDenied
            case .undetermined:
                let granted = await withCheckedContinuation { continuation in
                    session.requestRecordPermission { allowed in
                        continuation.resume(returning: allowed)
                    }
                }
                guard granted else {
                    throw RecognizerError.microphonePermissionDenied
                }
            @unknown default:
                throw RecognizerError.microphonePermissionDenied
            }
        }
    }
    
    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers]
            )
            try session.setActive(true, options: [])
        } catch {
            throw RecognizerError.audioSessionFailed("无法配置音频会话：\(error.localizedDescription)")
        }
    }
}


