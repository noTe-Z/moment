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
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            // Non-fatal
        }
    }

    private func startPlayback(for recording: Recording) {
        guard FileManager.default.fileExists(atPath: recording.fileURL.path) else {
            errorMessage = "录音文件不存在"
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers])
            try session.setActive(true, options: [])

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
