import Foundation

struct RecordingStore {
    static let recordingsDirectory: URL = {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Recordings", isDirectory: true)
    }()

    init() {
        ensureDirectoryExists()
    }

    func prepareFileURL(for date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let fileName = "recording_\(formatter.string(from: date)).m4a"
        return Self.recordingsDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    func fileName(from url: URL) -> String {
        url.lastPathComponent
    }

    func removeFile(named fileName: String) {
        let fileURL = Self.recordingsDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func ensureDirectoryExists() {
        if !FileManager.default.fileExists(atPath: Self.recordingsDirectory.path) {
            try? FileManager.default.createDirectory(at: Self.recordingsDirectory, withIntermediateDirectories: true)
        }
    }
}
