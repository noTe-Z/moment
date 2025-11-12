import Foundation
import AVFoundation

@MainActor
final class PlaybackManager: NSObject, ObservableObject {
    @Published private(set) var currentlyPlayingID: UUID?
    @Published var errorMessage: String?

    private var player: AVAudioPlayer?

    func toggle(recording: Recording) {
        if currentlyPlayingID == recording.id {
            stopPlayback()
        } else {
            startPlayback(for: recording)
        }
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        currentlyPlayingID = nil
        // 不要停用音频会话，因为可能有录音正在进行
        // 只有在确定没有其他音频活动时才停用
        // do {
        //     try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        // } catch {
        //     // Non-fatal
        // }
    }

    private func startPlayback(for recording: Recording) {
        guard FileManager.default.fileExists(atPath: recording.fileURL.path) else {
            errorMessage = "录音文件不存在"
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            
            // 只在必要时配置音频会话，避免中断正在进行的录音
            // 检查当前类别是否已经是 .playAndRecord
            if session.category != .playAndRecord {
                // 使用最温和的配置，确保不会中断录音
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .mixWithOthers, .allowBluetooth])
            }
            
            // 不要主动激活会话，让 AVAudioPlayer 自己处理
            // 这样可以避免中断正在进行的录音
            // if !session.isOtherAudioPlaying {
            //     try session.setActive(true, options: [.notifyOthersOnDeactivation])
            // }

            let newPlayer = try AVAudioPlayer(contentsOf: recording.fileURL)
            newPlayer.delegate = self
            newPlayer.prepareToPlay()
            newPlayer.play()

            player = newPlayer
            currentlyPlayingID = recording.id
            errorMessage = nil
        } catch {
            errorMessage = "播放失败"
            stopPlayback()
        }
    }
}

@MainActor
extension PlaybackManager: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            stopPlayback()
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            errorMessage = "播放错误"
            stopPlayback()
        }
    }
}
