import SwiftUI
import SwiftData

struct RepositoryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Recording.timestamp, order: .reverse) private var recordings: [Recording]
    @StateObject private var playbackManager = PlaybackManager()
    @State private var showPlaybackError = false
    private let recordingStore = RecordingStore()

    var body: some View {
        List {
            ForEach(groupedRecordings) { section in
                Section(section.title) {
                    ForEach(section.items) { recording in
                        RecordingRow(
                            recording: recording,
                            isPlaying: playbackManager.currentlyPlayingID == recording.id
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            playbackManager.toggle(recording: recording)
                        }
                        .listRowBackground(
                            playbackManager.currentlyPlayingID == recording.id
                            ? Color.accentColor.opacity(0.12)
                            : Color.clear
                        )
                    }
                    .onDelete { indexSet in
                        deleteRecordings(at: indexSet, in: section.items)
                    }
                }
            }
            if recordings.isEmpty {
                emptyState
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("我的录音")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("录音") {
                    dismiss()
                }
            }
        }
        .onChange(of: playbackManager.errorMessage) { newValue in
            showPlaybackError = newValue != nil
        }
        .alert("无法播放", isPresented: $showPlaybackError, actions: {
            Button("好的", role: .cancel) {
                playbackManager.errorMessage = nil
            }
        }, message: {
            Text(playbackManager.errorMessage ?? "请稍后再试。")
        })
        .onDisappear {
            playbackManager.stopPlayback()
        }
    }

    private var emptyState: some View {
        VStack(alignment: .center, spacing: 8) {
            Text("暂时没有录音")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("按住录音按钮，记录你的第一段微表达。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 48)
        .listRowBackground(Color.clear)
    }

    private var groupedRecordings: [RecordingSection] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: recordings) { recording in
            calendar.dateInterval(of: .weekOfYear, for: recording.timestamp)?.start ?? recording.timestamp
        }

        return groups.map { key, value in
            RecordingSection(
                id: key,
                title: WeekSectionFormatter.title(for: key),
                items: value.sorted(by: { $0.timestamp > $1.timestamp })
            )
        }
        .sorted(by: { $0.id > $1.id })
    }
    
    private func deleteRecordings(at offsets: IndexSet, in sectionItems: [Recording]) {
        for index in offsets {
            let recording = sectionItems[index]
            
            // 如果正在播放这个录音，先停止播放
            if playbackManager.currentlyPlayingID == recording.id {
                playbackManager.stopPlayback()
            }
            
            // 删除文件系统中的音频文件
            recordingStore.removeFile(named: recording.fileName)
            
            // 删除 SwiftData 中的记录
            modelContext.delete(recording)
        }
        
        // 保存更改
        try? modelContext.save()
    }
}

private struct RecordingSection: Identifiable {
    let id: Date
    let title: String
    let items: [Recording]
}

private struct RecordingRow: View {
    let recording: Recording
    let isPlaying: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(TimestampFormatter.display(for: recording.timestamp))
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("时长 \(TimeFormatter.display(for: recording.duration))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(isPlaying ? Color.accentColor : Color.secondary)
        }
        .padding(.vertical, 8)
    }
}
