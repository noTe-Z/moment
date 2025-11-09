import SwiftUI
import SwiftData

struct TextEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    let recording: Recording?
    let existingNote: TextNote?
    
    @State private var title: String
    @State private var content: String
    @State private var dragOffset: CGFloat = 0
    @State private var associatedRecording: Recording?
    @State private var showRecordingPanel = false
    @State private var showPlaybackError = false
    
    @StateObject private var playbackManager = PlaybackManager()
    
    // 用于跟踪是否是新创建的笔记
    private let isNewNote: Bool
    
    init(recording: Recording? = nil, existingNote: TextNote? = nil) {
        self.recording = recording
        self.existingNote = existingNote
        self.isNewNote = existingNote == nil
        
        // 初始化状态
        _title = State(initialValue: existingNote?.title ?? "")
        _content = State(initialValue: existingNote?.content ?? "")
        _associatedRecording = State(initialValue: recording)
    }
    
    var body: some View {
        ZStack {
            Color(UIColor.systemBackground)
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // 标题输入区
                TextField("标题", text: $title)
                    .font(.title2.bold())
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .background(Color(UIColor.systemBackground))
                
                Divider()
                
                // 内容输入区
                TextEditor(text: $content)
                    .font(.body)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .scrollContentBackground(.hidden)
                    .background(Color(UIColor.systemBackground))
            }
            .offset(x: dragOffset)
        }
        .navigationBarBackButtonHidden(true)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    saveAndDismiss()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("返回")
                    }
                }
            }
            
            ToolbarItemGroup(placement: .bottomBar) {
                if associatedRecording != nil {
                    Button {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            showRecordingPanel.toggle()
                        }
                    } label: {
                        RecordingAccessoryIcon(isActive: showRecordingPanel)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("显示关联录音")
                }
                
                Spacer()
            }
        }
        .gesture(
            DragGesture()
                .onChanged { value in
                    // 只允许从左向右拖动
                    if value.translation.width > 0 {
                        dragOffset = value.translation.width
                    }
                }
                .onEnded { value in
                    // 如果拖动超过屏幕宽度的 1/3，就关闭
                    if value.translation.width > UIScreen.main.bounds.width / 3 {
                        saveAndDismiss()
                    } else {
                        // 否则弹回
                        withAnimation(.spring(response: 0.3)) {
                            dragOffset = 0
                        }
                    }
                }
        )
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showRecordingPanel, let associatedRecording {
                RecordingPreviewPanel(
                    recording: associatedRecording,
                    isPlaying: playbackManager.currentlyPlayingID == associatedRecording.id,
                    playAction: { playbackManager.toggle(recording: associatedRecording) }
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear {
            resolveAssociatedRecordingIfNeeded()
        }
        .onDisappear {
            playbackManager.stopPlayback()
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
    }
    
    private func saveAndDismiss() {
        // 只有在标题或内容不为空时才保存
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
           !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            
            if let existingNote = existingNote {
                // 更新现有笔记
                existingNote.title = title
                existingNote.content = content
                existingNote.updatedAt = Date()
                if existingNote.recordingID == nil {
                    existingNote.recordingID = (associatedRecording ?? recording)?.id
                }
            } else {
                // 创建新笔记
                let newNote = TextNote(
                    title: title.isEmpty ? "无标题" : title,
                    content: content,
                    recordingID: (associatedRecording ?? recording)?.id
                )
                modelContext.insert(newNote)
            }
            
            try? modelContext.save()
        }
        
        dismiss()
    }
    
    private func resolveAssociatedRecordingIfNeeded() {
        if associatedRecording == nil, let targetID = existingNote?.recordingID {
            let descriptor = FetchDescriptor<Recording>(predicate: #Predicate { $0.id == targetID })
            if let resolved = try? modelContext.fetch(descriptor).first {
                associatedRecording = resolved
            }
        }
    }
}

// MARK: - Supporting Views

private struct RecordingAccessoryIcon: View {
    let isActive: Bool
    
    var body: some View {
        Image(systemName: "list.bullet.circle\(isActive ? ".fill" : "")")
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
            .padding(10)
            .background(
                Circle()
                    .fill(
                        isActive
                        ? Color.accentColor.opacity(0.12)
                        : Color.secondary.opacity(0.1)
                    )
            )
    }
}

private struct RecordingPreviewPanel: View {
    let recording: Recording
    let isPlaying: Bool
    let playAction: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("关联录音")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(TimestampFormatter.display(for: recording.timestamp))
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("时长 \(TimeFormatter.display(for: recording.duration))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Button(action: playAction) {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(isPlaying ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(UIColor.secondarySystemBackground))
            )
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.thinMaterial)
        )
        .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 6)
    }
}

