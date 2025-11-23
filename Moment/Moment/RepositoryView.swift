import SwiftUI
import SwiftData

struct RepositoryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab = 0
    
    var body: some View {
        VStack(spacing: 0) {
            // Tab 内容区域 - 使用条件渲染替代 TabView，避免滑动冲突
            Group {
                if selectedTab == 0 {
                    RecordingsListView()
                } else {
                    TextNotesView()
                }
            }
            
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
    @Query(sort: \TextNote.updatedAt, order: .reverse) private var textNotes: [TextNote]
    @StateObject private var playbackManager = PlaybackManager()
    @State private var showPlaybackError = false
    @State private var selectedRecordingForEdit: Recording?
    @State private var recordingForNoteSelection: Recording?
    @State private var addToNoteNavigationTarget: AddToNoteNavigationTarget?
    private let recordingStore = RecordingStore()
    @State private var transcriptViewerRecording: Recording?
    private let transcriptionManager = RecordingTranscriptionManager.shared

    var body: some View {
        recordingsList
    }
    
    private var recordingsList: some View {
        List {
            recordingSections
            if recordings.isEmpty {
                emptyState
            }
        }
        .listStyle(.insetGrouped)
        .sheet(item: $recordingForNoteSelection) { recording in
            NavigationStack {
                AddRecordingToNoteSheet(
                    recording: recording,
                    notes: textNotes,
                    selectAction: { note in
                        recordingForNoteSelection = nil
                        attachRecording(recording, to: note)
                    },
                    createNewAction: {
                        recordingForNoteSelection = nil
                        selectedRecordingForEdit = recording
                    },
                    cancelAction: {
                        recordingForNoteSelection = nil
                    }
                )
            }
        }
        .sheet(item: $transcriptViewerRecording) { recording in
            RecordingTranscriptSheet(recording: recording)
        }
        .navigationDestination(item: $selectedRecordingForEdit) { recording in
            TextEditorView(recording: recording)
        }
        .navigationDestination(item: $addToNoteNavigationTarget) { target in
            TextEditorView(recording: target.recording, existingNote: target.note)
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
        .onAppear {
            ensureTranscriptions()
        }
        .onChange(of: recordings.map(\.id)) { _ in
            ensureTranscriptions()
        }
    }

    @ViewBuilder
    private var recordingSections: some View {
        ForEach(groupedRecordings) { section in
            Section(section.title) {
                ForEach(section.items) { recording in
                    RecordingListItem(
                        recording: recording,
                        isPlaying: playbackManager.currentlyPlayingID == recording.id,
                        onTogglePlay: {
                            playbackManager.toggle(recording: recording)
                        },
                        onDelete: {
                            if let index = section.items.firstIndex(where: { $0.id == recording.id }) {
                                deleteRecordings(at: IndexSet([index]), in: section.items)
                            }
                        },
                        onAddToNote: {
                            recordingForNoteSelection = recording
                        },
                        onViewTranscript: {
                            transcriptViewerRecording = recording
                        },
                        onRetryTranscription: {
                            transcriptionManager.retryTranscription(for: recording, in: modelContext)
                        }
                    )
                }
            }
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
    
    private func attachRecording(_ recording: Recording, to note: TextNote) {
        note.appendRecordingID(recording.id)
        note.updatedAt = Date()
        try? modelContext.save()
        transcriptionManager.ensureTranscript(for: recording, in: modelContext)
        addToNoteNavigationTarget = AddToNoteNavigationTarget(note: note, recording: recording)
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
    
    private func ensureTranscriptions() {
        guard !recordings.isEmpty else { return }
        transcriptionManager.ensureTranscripts(for: recordings, in: modelContext)
    }
}

private struct RecordingSection: Identifiable {
    let id: Date
    let title: String
    let items: [Recording]
}

private struct AddToNoteNavigationTarget: Identifiable, Hashable {
    let note: TextNote
    let recording: Recording
    
    var id: UUID { note.id }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(note.id)
        hasher.combine(recording.id)
    }
    
    static func == (lhs: AddToNoteNavigationTarget, rhs: AddToNoteNavigationTarget) -> Bool {
        lhs.note.id == rhs.note.id && lhs.recording.id == rhs.recording.id
    }
}

private struct RecordingListItem: View {
    let recording: Recording
    let isPlaying: Bool
    let onTogglePlay: () -> Void
    let onDelete: () -> Void
    let onAddToNote: () -> Void
    let onViewTranscript: () -> Void
    let onRetryTranscription: () -> Void
    
    var body: some View {
        RecordingRow(
            recording: recording,
            isPlaying: isPlaying,
            onViewTranscript: onViewTranscript,
            onRetryTranscription: onRetryTranscription
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onTogglePlay()
        }
        .listRowBackground(
            isPlaying
            ? Color.accentColor.opacity(0.12)
            : Color.clear
        )
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("删除", systemImage: "trash")
            }
            
            Button {
                onAddToNote()
            } label: {
                Label("添加", systemImage: "plus.circle")
            }
            .tint(.blue)
        }
        .contextMenu {
            Button("查看转写") {
                onViewTranscript()
            }
            .disabled(!recording.hasTranscript)
            
            Button("重新转写") {
                onRetryTranscription()
            }
            .disabled(!recording.canManualRetryTranscription)
        }
    }
}

private struct RecordingRow: View {
    let recording: Recording
    let isPlaying: Bool
    let onViewTranscript: () -> Void
    let onRetryTranscription: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                if let title = recording.title, !title.isEmpty {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    
                    HStack(spacing: 4) {
                        Text(TimestampFormatter.display(for: recording.timestamp))
                        Text("·")
                        Text(TimeFormatter.display(for: recording.duration))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text(TimestampFormatter.display(for: recording.timestamp))
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("时长 \(TimeFormatter.display(for: recording.duration))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                
                if let status = statusText {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                }
            }
            Spacer()
            transcriptAccessory
            Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(isPlaying ? Color.accentColor : Color.secondary)
        }
        .padding(.vertical, 8)
    }
    
    @ViewBuilder
    private var transcriptAccessory: some View {
        switch recording.transcriptionStatus {
        case .processing:
            ProgressView()
                .progressViewStyle(.circular)
                .frame(width: 24, height: 24)
        case .failed:
            Button(action: onRetryTranscription) {
                Image(systemName: "arrow.clockwise.circle")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .disabled(!recording.canManualRetryTranscription)
        case .completed:
            Button(action: onViewTranscript) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
        case .queued:
            if recording.hasTranscript {
                Button(action: onViewTranscript) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            } else if recording.isWaitingForScheduledRetry {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.orange)
            } else {
                Image(systemName: "hourglass")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        case .idle:
            if recording.hasTranscript {
                Button(action: onViewTranscript) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "text.badge.plus")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    private var statusText: String? {
        switch recording.transcriptionStatus {
        case .processing:
            return "转写中…"
        case .failed:
            return recording.transcriptionErrorMessage ?? "转写失败"
        case .queued:
            return recording.queuedStatusDescription() ?? (recording.hasTranscript ? nil : "排队等待转写")
        case .idle:
            return recording.hasTranscript ? nil : "等待转写"
        case .completed:
            return nil
        }
    }
    
    private var statusColor: Color {
        switch recording.transcriptionStatus {
        case .failed:
            return .orange
        case .processing:
            return .secondary
        case .queued:
            return recording.isWaitingForScheduledRetry ? .orange : .secondary
        case .idle:
            return .secondary
        case .completed:
            return .secondary
        }
    }
}

private struct AddRecordingToNoteSheet: View {
    let recording: Recording
    let notes: [TextNote]
    let selectAction: (TextNote) -> Void
    let createNewAction: () -> Void
    let cancelAction: () -> Void
    
    var body: some View {
        List {
            Section("当前录音") {
                RecordingSummaryRow(recording: recording)
                Text("选择一个文本文档，将该录音展示在文本编辑页的关联面板中。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            
            Section("选择文本文档") {
                if notes.isEmpty {
                    EmptyNotesPlaceholder()
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(notes) { note in
                        Button {
                            selectAction(note)
                        } label: {
                            NoteSelectionRow(
                                note: note,
                                isLinkedToCurrentRecording: note.allRecordingIDs.contains(recording.id),
                                totalLinkedCount: note.allRecordingIDs.count
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) {
            Button {
                createNewAction()
            } label: {
                Label("新建结构化表达", systemImage: "square.and.pencil")
                    .font(.headline)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .navigationTitle("添加到文本")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("完成") {
                    cancelAction()
                }
            }
        }
    }
}

private struct RecordingSummaryRow: View {
    let recording: Recording
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title = recordingTitle {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text("\(TimestampFormatter.display(for: recording.timestamp)) · \(TimeFormatter.display(for: recording.duration))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text(TimestampFormatter.display(for: recording.timestamp))
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("时长 \(TimeFormatter.display(for: recording.duration))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
    
    private var recordingTitle: String? {
        guard let trimmed = recording.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

private struct NoteSelectionRow: View {
    let note: TextNote
    let isLinkedToCurrentRecording: Bool
    let totalLinkedCount: Int
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Text(note.title.isEmpty ? "无标题" : note.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                
                Spacer()
                
                if isLinkedToCurrentRecording {
                    AttachmentStatusTag(
                        text: "已关联",
                        background: Color.accentColor.opacity(0.15),
                        foreground: Color.accentColor
                    )
                } else if totalLinkedCount > 0 {
                    AttachmentStatusTag(
                        text: "已有 \(totalLinkedCount) 个录音",
                        background: Color.secondary.opacity(0.12),
                        foreground: Color.secondary
                    )
                }
                
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            
            if let preview = contentPreview {
                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            
            Text("更新于 \(TimestampFormatter.display(for: note.updatedAt))")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
    
    private var contentPreview: String? {
        let trimmed = note.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count > 120 {
            let endIndex = trimmed.index(trimmed.startIndex, offsetBy: 120)
            return "\(trimmed[..<endIndex])…"
        }
        return trimmed
    }
}

private struct AttachmentStatusTag: View {
    let text: String
    let background: Color
    let foreground: Color
    
    var body: some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(background)
            )
            .foregroundStyle(foreground)
    }
}

private struct EmptyNotesPlaceholder: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("还没有文本文档")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("先创建一个结构化表达，再把录音添加进去。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 24)
    }
}
