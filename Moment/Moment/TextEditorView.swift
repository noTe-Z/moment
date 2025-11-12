import SwiftUI
import SwiftData
import Combine

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
    @StateObject private var recorderViewModel = TextEditorRecorderViewModel()
    
    @State private var recorderErrorMessage: String?
    @State private var showRecorderError = false
    
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
        AnyView(
            mainContent
                .navigationBarBackButtonHidden(true)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .gesture(dismissDragGesture)
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
        .onReceive(recorderViewModel.$presentableError) { error in
            guard let error else { return }
            recorderErrorMessage = error.errorDescription ?? "发生未知错误。"
            showRecorderError = true
        }
        .alert("无法播放", isPresented: $showPlaybackError, actions: {
            Button("好的", role: .cancel) {
                playbackManager.errorMessage = nil
            }
        }, message: {
            Text(playbackManager.errorMessage ?? "请稍后再试。")
        })
        .alert("语音转文字失败", isPresented: $showRecorderError, actions: {
            Button("好的", role: .cancel) {
                recorderErrorMessage = nil
                recorderViewModel.presentableError = nil
            }
        }, message: {
            Text(recorderErrorMessage ?? "请稍后再试。")
        })
    }
    
    private var mainContent: some View {
        ZStack {
            Color(UIColor.systemBackground)
                .ignoresSafeArea()
            editorContent
        }
    }
    
    private var editorContent: some View {
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
    
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            leadingToolbarButton
        }
        
        ToolbarItemGroup(placement: .bottomBar) {
            recorderToolbarButton
            Spacer()
            associatedRecordingToolbarButton
        }
    }
    
    private var leadingToolbarButton: some View {
        Button {
            saveAndDismiss()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                Text("返回")
            }
        }
    }
    
    private var recorderToolbarButton: some View {
        RecorderControlButton(
            mode: recorderViewModel.mode,
            elapsedText: recorderViewModel.elapsedDisplay,
            statusText: recorderViewModel.statusMessage,
            action: handleRecorderButtonTapped
        )
    }
    
    @ViewBuilder
    private var associatedRecordingToolbarButton: some View {
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
    }
    
    private var dismissDragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if value.translation.width > 0 {
                    dragOffset = value.translation.width
                }
            }
            .onEnded { value in
                if value.translation.width > UIScreen.main.bounds.width / 3 {
                    saveAndDismiss()
                } else {
                    withAnimation(.spring(response: 0.3)) {
                        dragOffset = 0
                    }
                }
            }
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
    
    private func handleRecorderButtonTapped() {
        Task { @MainActor in
            switch recorderViewModel.mode {
            case .idle, .failed:
                do {
                    try await recorderViewModel.startRecording()
                } catch {
                    if let recorderError = error as? TextEditorRecorderViewModel.RecorderError {
                        recorderErrorMessage = recorderError.errorDescription ?? recorderError.localizedDescription
                    } else {
                        recorderErrorMessage = error.localizedDescription
                    }
                    showRecorderError = true
                }
            case .recording:
                do {
                    let transcript = try await recorderViewModel.stopRecordingAndTranscribe()
                    appendTranscript(transcript)
                } catch {
                    if let recorderError = error as? TextEditorRecorderViewModel.RecorderError {
                        recorderErrorMessage = recorderError.errorDescription ?? recorderError.localizedDescription
                    } else {
                        recorderErrorMessage = error.localizedDescription
                    }
                    showRecorderError = true
                }
            case .uploading, .transcribing:
                break
            }
        }
    }
    
    private func appendTranscript(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        if content.isEmpty {
            content = trimmed
        } else {
            if !content.hasSuffix("\n") {
                content.append("\n")
            }
            content.append(trimmed)
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

private struct RecorderControlButton: View {
    let mode: TextEditorRecorderViewModel.Mode
    let elapsedText: String
    let statusText: String?
    let action: () -> Void
    
    private var isRecording: Bool {
        mode == .recording
    }
    
    private var isProcessing: Bool {
        mode == .uploading || mode == .transcribing
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: action) {
                HStack(alignment: .center, spacing: 12) {
                    if isProcessing {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(isRecording ? Color.white : Color.accentColor)
                    } else {
                        Image(systemName: isRecording ? "stop.circle.fill" : "mic.circle.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .symbolRenderingMode(.monochrome)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(buttonTitle)
                            .font(.headline)
                            .fontWeight(.semibold)
                        if isRecording {
                            Text(elapsedText)
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(Color.white.opacity(0.85))
                        } else if let statusText, !statusText.isEmpty, !isProcessing {
                            Text(statusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(background)
                .foregroundStyle(foregroundStyle)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isProcessing)
            
            if isProcessing, let statusText {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    private var buttonTitle: String {
        switch mode {
        case .idle, .failed:
            return "语音转文字"
        case .recording:
            return "点击结束并转写"
        case .uploading:
            return "正在上传"
        case .transcribing:
            return "转写中..."
        }
    }
    
    @ViewBuilder
    private var background: some View {
        if isRecording {
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.92),
                    Color.accentColor
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else if isProcessing {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.accentColor.opacity(0.15))
        } else {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(UIColor.secondarySystemBackground))
        }
    }
    
    private var foregroundStyle: some ShapeStyle {
        isRecording ? Color.white : (isProcessing ? Color.accentColor : Color.primary)
    }
}


