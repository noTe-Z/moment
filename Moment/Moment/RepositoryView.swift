import SwiftUI
import SwiftData

struct RepositoryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab = 0
    
    var body: some View {
        VStack(spacing: 0) {
            // Tab 内容区域
            TabView(selection: $selectedTab) {
                RecordingsListView()
                    .tag(0)
                
                TextNotesView()
                    .tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            
            // 自定义底部 Tab Bar
            Divider()
            HStack(spacing: 0) {
                TabButton(title: "录音", systemImage: "waveform", isSelected: selectedTab == 0) {
                    withAnimation {
                        selectedTab = 0
                    }
                }
                
                TabButton(title: "文本编辑", systemImage: "square.and.pencil", isSelected: selectedTab == 1) {
                    withAnimation {
                        selectedTab = 1
                    }
                }
            }
            .frame(height: 50)
            .background(Color(UIColor.systemBackground))
        }
        .navigationTitle(selectedTab == 0 ? "我的录音" : "结构化表达")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("录音") {
                    dismiss()
                }
            }
        }
    }
}

private struct TabButton: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 20))
                Text(title)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        }
    }
}

struct RecordingsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Recording.timestamp, order: .reverse) private var recordings: [Recording]
    @StateObject private var playbackManager = PlaybackManager()
    @State private var showPlaybackError = false
    @State private var selectedRecordingForEdit: Recording?
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
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            // 删除按钮
                            Button(role: .destructive) {
                                if let index = section.items.firstIndex(where: { $0.id == recording.id }) {
                                    deleteRecordings(at: IndexSet([index]), in: section.items)
                                }
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            
                            // 文本编辑按钮
                            Button {
                                selectedRecordingForEdit = recording
                            } label: {
                                Label("编辑", systemImage: "square.and.pencil")
                            }
                            .tint(.blue)
                        }
                    }
                }
            }
            if recordings.isEmpty {
                emptyState
            }
        }
        .listStyle(.insetGrouped)
        .navigationDestination(item: $selectedRecordingForEdit) { recording in
            TextEditorView(recording: recording)
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
