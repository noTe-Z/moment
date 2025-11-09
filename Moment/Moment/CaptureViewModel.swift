import Foundation
import AVFoundation
import SwiftData
import UIKit

@MainActor
final class CaptureViewModel: ObservableObject {
    enum StatusIndicator: Equatable {
        case hidden
        case timer(String)
        case message(String)
    }

    @Published private(set) var isRecording = false
    @Published var status: StatusIndicator = .hidden
    @Published var microphoneDenied = false

    private let store = RecordingStore()
    private var context: ModelContext?
    private var audioRecorder: AVAudioRecorder?
    private var startDate: Date?
    private var fileURL: URL?
    private var timer: Timer?

    init() {
        // 监听音频会话中断
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func bind(context: ModelContext) {
        self.context = context
    }

    func prepareSession() async {
        _ = await ensurePermission()
    }

    func beginRecording() {
        Task { [weak self] in
            guard let self else { return }
            await self.startRecording()
        }
    }

    private func startRecording() async {
        guard !isRecording else { return }
        guard await ensurePermission() else { return }
        guard let context else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            // 使用强制配置，确保录音不会被其他操作中断
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers, .duckOthers]
            )
            try session.setActive(true, options: [])

            let now = Date()
            let url = store.prepareFileURL(for: now)
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            recorder.record()

            audioRecorder = recorder
            startDate = now
            fileURL = url
            isRecording = true
            status = .timer("00:00")
            startTimer()
            Haptic.trigger(.light)
            
            print("✅ 录音已开始")
        } catch {
            status = .message("录音失败")
            print("❌ 录音启动失败：\(error)")
        }
    }
    
    @objc private func handleAudioInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        Task { @MainActor in
            switch type {
            case .began:
                // 中断开始：不做任何处理，让录音继续
                // 使用 .mixWithOthers 选项应该允许录音继续进行
                print("⚠️ 音频会话中断开始，但录音应该继续")
            case .ended:
                // 中断结束：确保音频会话仍然活跃
                guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                
                if options.contains(.shouldResume) || isRecording {
                    do {
                        // 确保音频会话处于正确的配置
                        let session = AVAudioSession.sharedInstance()
                        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
                        try session.setActive(true, options: [])
                        
                        // 如果录音器存在且正在录音，确保它仍在录音
                        if let recorder = audioRecorder, isRecording {
                            if !recorder.isRecording {
                                recorder.record()
                                print("✅ 录音已恢复")
                            }
                        }
                    } catch {
                        print("❌ 无法恢复音频会话：\(error)")
                    }
                }
            @unknown default:
                break
            }
        }
    }

    func finishRecording() {
        guard isRecording else { return }
        guard let startDate else {
            status = .hidden
            return
        }
        
        // 在停止录音之前获取时长
        // 优先使用 currentTime，如果无效则使用时间差计算（更可靠）
        let recorderDuration = audioRecorder?.currentTime ?? 0
        let timeBasedDuration = Date().timeIntervalSince(startDate)
        let duration = recorderDuration > 0 ? recorderDuration : timeBasedDuration
        
        audioRecorder?.stop()
        audioRecorder = nil
        stopTimer()
        isRecording = false

        guard
            let context,
            let fileURL
        else {
            status = .hidden
            return
        }
        let recording = Recording(timestamp: startDate, duration: duration, fileName: store.fileName(from: fileURL))

        do {
            context.insert(recording)
            try context.save()
            status = .message("已保存")
            Haptic.trigger(.light)
            scheduleReset()
        } catch {
            status = .message("保存失败")
            store.removeFile(named: recording.fileName)
        }

        self.startDate = nil
        self.fileURL = nil

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            // Ignored: deactivation errors are non-fatal here
        }
    }

    func handlePermissionDeniedDismissal() {
        status = .message("请在设置中启用麦克风")
        scheduleReset()
    }

    func cancelActiveRecording() {
        if isRecording {
            audioRecorder?.stop()
            if let fileName = fileURL?.lastPathComponent {
                store.removeFile(named: fileName)
            }
        }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            // Non-fatal
        }
        stopTimer()
        isRecording = false
        status = .hidden
        startDate = nil
        fileURL = nil
        audioRecorder = nil
    }

    private func scheduleReset() {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            if let self, !self.isRecording {
                self.status = .hidden
            }
        }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, self.isRecording, let startDate = self.startDate else { return }
            let elapsed = Date().timeIntervalSince(startDate)
            self.status = .timer(TimeFormatter.display(for: elapsed))
            
            // 检查录音器是否真的在录音，如果没有就尝试恢复
            if let recorder = self.audioRecorder, !recorder.isRecording {
                print("⚠️ 检测到录音被暂停，尝试恢复...")
                do {
                    // 重新激活音频会话
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
                    try session.setActive(true, options: [])
                    // 恢复录音
                    recorder.record()
                    print("✅ 录音已自动恢复")
                } catch {
                    print("❌ 无法恢复录音：\(error)")
                }
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func ensurePermission() async -> Bool {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            return true
        case .denied:
            microphoneDenied = true
            return false
        case .undetermined:
            let granted = await withCheckedContinuation { continuation in
                session.requestRecordPermission { allowed in
                    continuation.resume(returning: allowed)
                }
            }
            microphoneDenied = !granted
            return granted
        @unknown default:
            microphoneDenied = true
            return false
        }
    }
}

private enum Haptic {
    static func trigger(_ style: Style) {
        let generator = UIImpactFeedbackGenerator(style: style.impactStyle)
        generator.impactOccurred(intensity: style.intensity)
    }

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
}
