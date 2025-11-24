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
    @State private var associatedRecordings: [Recording]
    @State private var showRecordingPanel = false
    @State private var highlightedRecordingID: UUID?
    @State private var showPlaybackError = false
    @State private var isRewriting = false
    @State private var showRewritePreview = false
    @State private var pendingRewrite: String?
    @State private var rewriteSourceSnapshot: String = ""
    @State private var rewriteErrorMessage: String?
    @State private var showRewriteError = false
    
    @StateObject private var playbackManager = PlaybackManager()
    @StateObject private var recorderViewModel = TextEditorRecorderViewModel()
    
    @State private var recorderErrorMessage: String?
    @State private var showRecorderError = false
    @State private var transcriptViewerRecording: Recording?
    @State private var showNarrationCoach = false
    
    private let transcriptionManager = RecordingTranscriptionManager.shared
    
    // 用于跟踪是否是新创建的笔记
    private let isNewNote: Bool
    private let rewriteService = OpenAIRewriteService()
    
    init(recording: Recording? = nil, existingNote: TextNote? = nil) {
        self.recording = recording
        self.existingNote = existingNote
        self.isNewNote = existingNote == nil
        
        // 初始化状态
        _title = State(initialValue: existingNote?.title ?? "")
        _content = State(initialValue: existingNote?.content ?? "")
        _associatedRecordings = State(initialValue: recording.map { [$0] } ?? [])
        _highlightedRecordingID = State(initialValue: recording?.id)
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
            if showRecordingPanel, !associatedRecordings.isEmpty {
                RecordingPreviewListPanel(
                    recordings: associatedRecordings,
                    highlightedRecordingID: highlightedRecordingID,
                    currentlyPlayingID: playbackManager.currentlyPlayingID,
                    playAction: { recording in
                        highlightedRecordingID = recording.id
                        playbackManager.toggle(recording: recording)
                    },
                    viewTranscriptAction: { recording in
                        transcriptViewerRecording = recording
                    },
                    retryTranscriptionAction: { recording in
                        transcriptionManager.retryTranscription(for: recording, in: modelContext)
                    }
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear {
            loadAssociatedRecordingsIfNeeded()
            ensureTranscriptionsForAssociatedRecordings()
        }
        .onDisappear {
            playbackManager.stopPlayback()
        }
        .onChange(of: associatedRecordings.map(\.id)) { _ in
            ensureTranscriptionsForAssociatedRecordings()
        }
        .onChange(of: playbackManager.errorMessage) { newValue in
            showPlaybackError = newValue != nil
        }
        .onReceive(recorderViewModel.$presentableError) { error in
            guard let error else { return }
            recorderErrorMessage = error.errorDescription ?? "发生未知错误。"
            showRecorderError = true
        }
        .onChange(of: recorderViewModel.pendingFallbackRecording) { snapshot in
            guard let snapshot else { return }
            persistFailedRecordingSnapshot(snapshot)
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
        .alert("生成段落失败", isPresented: $showRewriteError, actions: {
            Button("好的", role: .cancel) {
                rewriteErrorMessage = nil
            }
        }, message: {
            Text(rewriteErrorMessage ?? "请稍后再试。")
        })
        .sheet(isPresented: $showRewritePreview, onDismiss: {
            pendingRewrite = nil
            rewriteSourceSnapshot = ""
        }) {
            if let pendingRewrite {
                RewritePreviewSheet(
                    original: rewriteSourceSnapshot,
                    suggestion: pendingRewrite,
                    confirmAction: { applyRewrite(with: pendingRewrite) },
                    cancelAction: { dismissRewritePreview() }
                )
                .presentationDetents([.medium, .large])
            } else {
                ProgressView()
                    .progressViewStyle(.circular)
                    .padding()
            }
        }
        .sheet(item: $transcriptViewerRecording) { recording in
            RecordingTranscriptSheet(recording: recording)
        }
        .sheet(isPresented: $showNarrationCoach) {
            NarrationCoachSheet(
                noteTitle: title,
                noteContent: content
            )
        }
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
            
            if !hasMainThreadHeading {
                MainThreadHintView(insertAction: insertMainThreadHeading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            
            // 内容输入区
            ZStack(alignment: .topLeading) {
                TextEditor(text: $content)
                    .font(.body)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .scrollContentBackground(.hidden)
                    .background(Color(UIColor.systemBackground))
                
                if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("示例：# 核心主线\n在此总结主线，再换行记录其他段落。")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 18)
                        .allowsHitTesting(false)
                }
            }
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
            rewriteToolbarButton
            narrationCoachToolbarButton
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
    
    private var rewriteToolbarButton: some View {
        let isDisabled = isRewriting || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        
        return Button {
            handleRewriteButtonTapped()
        } label: {
            HStack(alignment: .center, spacing: 12) {
                if isRewriting {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(Color.accentColor)
                } else {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 22, weight: .semibold))
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("整理段落")
                        .font(.headline)
                        .fontWeight(.semibold)
                    Text("AI 辅助")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isDisabled ? Color(UIColor.secondarySystemBackground) : Color.accentColor.opacity(0.15))
            )
            .foregroundStyle(isDisabled ? Color.secondary : Color.primary)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel("使用 AI 整理当前内容")
    }
    
    private var narrationCoachToolbarButton: some View {
        Button {
            showNarrationCoach = true
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "bubble.left.and.waveform.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("口播教练")
                        .font(.headline)
                        .fontWeight(.semibold)
                    Text("GPT Realtime")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(UIColor.secondarySystemBackground))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("打开口播练习教练")
    }
    
    @ViewBuilder
    private var associatedRecordingToolbarButton: some View {
        if !associatedRecordings.isEmpty {
            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    showRecordingPanel.toggle()
                }
            } label: {
                RecordingAccessoryIcon(isActive: showRecordingPanel, count: associatedRecordings.count)
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
            
            let currentRecordingIDs = recordingIDsForPersistence
            
            if let existingNote = existingNote {
                // 更新现有笔记
                existingNote.title = title
                existingNote.content = content
                existingNote.updatedAt = Date()
                existingNote.setRecordingIDs(currentRecordingIDs)
            } else {
                // 创建新笔记
                let newNote = TextNote(
                    title: title.isEmpty ? "无标题" : title,
                    content: content,
                    recordingIDs: currentRecordingIDs
                )
                modelContext.insert(newNote)
            }
            
            try? modelContext.save()
        }
        
        dismiss()
    }
    
    private func loadAssociatedRecordingsIfNeeded() {
        var merged: [Recording] = associatedRecordings
        var orderMap: [UUID: Int] = [:]
        
        if let existingNote {
            existingNote.migrateLegacyRecordingIfNeeded()
            let ids = existingNote.allRecordingIDs
            for (index, id) in ids.enumerated() {
                orderMap[id] = index
            }
            
            if !ids.isEmpty {
                let descriptor = FetchDescriptor<Recording>(predicate: #Predicate { ids.contains($0.id) })
                if let fetched = try? modelContext.fetch(descriptor) {
                    merged.append(contentsOf: fetched)
                }
            }
        }
        
        if let recording {
            merged.append(recording)
            if orderMap[recording.id] == nil {
                orderMap[recording.id] = -1
            }
        }
        
        let unique = uniqueRecordings(from: merged)
        associatedRecordings = unique.sorted { lhs, rhs in
            let lhsOrder = orderMap[lhs.id] ?? Int.max
            let rhsOrder = orderMap[rhs.id] ?? Int.max
            if lhsOrder == rhsOrder {
                return lhs.timestamp > rhs.timestamp
            }
            return lhsOrder < rhsOrder
        }
        
        if highlightedRecordingID == nil {
            highlightedRecordingID = recording?.id ?? associatedRecordings.first?.id
        }
        
        ensureTranscriptionsForAssociatedRecordings()
    }
    
    private func uniqueRecordings(from recordings: [Recording]) -> [Recording] {
        var seen = Set<UUID>()
        var result: [Recording] = []
        for recording in recordings {
            if !seen.contains(recording.id) {
                seen.insert(recording.id)
                result.append(recording)
            }
        }
        return result
    }
    
    private func ensureTranscriptionsForAssociatedRecordings() {
        guard !associatedRecordings.isEmpty else { return }
        transcriptionManager.ensureTranscripts(for: associatedRecordings, in: modelContext)
    }
    
    private var recordingIDsForPersistence: [UUID] {
        var ids = associatedRecordings.map(\.id)
        if ids.isEmpty {
            if let recording {
                ids = [recording.id]
            } else if let existingNote {
                ids = existingNote.allRecordingIDs
            }
        }
        
        var unique: [UUID] = []
        for id in ids where !unique.contains(id) {
            unique.append(id)
        }
        return unique
    }

    private func persistFailedRecordingSnapshot(_ snapshot: TextEditorRecorderViewModel.RecordingSnapshot) {
        let recording = Recording(
            timestamp: snapshot.timestamp,
            duration: snapshot.duration,
            fileName: snapshot.fileName
        )
        modelContext.insert(recording)
        try? modelContext.save()
        associatedRecordings = uniqueRecordings(from: [recording] + associatedRecordings)
        highlightedRecordingID = recording.id
        showRecordingPanel = true
        existingNote?.appendRecordingID(recording.id)
        try? modelContext.save()
        recorderViewModel.markFallbackRecordingHandled()
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
    
    private func handleRewriteButtonTapped() {
        let requestText = buildAIRequestText()
        guard !requestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            rewriteErrorMessage = "当前没有可整理的内容。"
            showRewriteError = true
            return
        }
        
        if isRewriting {
            return
        }
        
        isRewriting = true
        rewriteSourceSnapshot = content
        
        Task {
            do {
                let result = try await rewriteService.rewrite(text: requestText)
                await MainActor.run {
                    pendingRewrite = result
                    showRewritePreview = true
                }
            } catch let error as OpenAIRewriteService.RewriteError {
                await MainActor.run {
                    rewriteErrorMessage = error.errorDescription ?? error.localizedDescription
                    showRewriteError = true
                }
            } catch {
                await MainActor.run {
                    rewriteErrorMessage = error.localizedDescription
                    showRewriteError = true
                }
            }
            
            await MainActor.run {
                isRewriting = false
            }
        }
    }
    
    private func applyRewrite(with suggestion: String) {
        content = suggestion
        pendingRewrite = nil
        showRewritePreview = false
        rewriteSourceSnapshot = ""
    }
    
    private func dismissRewritePreview() {
        pendingRewrite = nil
        showRewritePreview = false
        rewriteSourceSnapshot = ""
    }
    
    private var hasMainThreadHeading: Bool {
        guard let firstLine = content
            .components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return false
        }
        
        let normalized = firstLine.trimmingCharacters(in: .whitespaces)
        let lowercased = normalized.lowercased()
        return lowercased.hasPrefix("# 核心主线") || lowercased.hasPrefix("# main thread")
    }
    
    private func insertMainThreadHeading() {
        guard !hasMainThreadHeading else { return }
        let heading = "# 核心主线"
        let trimmedBody = content.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let additionalSection = "\n# 其他内容\n\n"

        if trimmedBody.isEmpty {
            content = "\(heading)\n\n\(additionalSection)"
        } else {
            content = "\(heading)\n\n\(trimmedBody)\(additionalSection)"
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
    
    private func buildAIRequestText() -> String {
        var payload = content
        let trimmedContent = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedContent.isEmpty {
            payload = ""
        }
        
        let transcriptBlocks = transcriptContextBlocks()
        guard !transcriptBlocks.isEmpty else {
            return payload.isEmpty ? trimmedContent : payload
        }
        
        var appendableBlocks = ["# 关联录音转写（隐藏）"]
        appendableBlocks.append(contentsOf: transcriptBlocks)
        let transcriptSection = appendableBlocks.joined(separator: "\n\n")
        
        if payload.isEmpty {
            return transcriptSection
        } else {
            return payload + "\n\n" + transcriptSection
        }
    }
    
    private func transcriptContextBlocks() -> [String] {
        associatedRecordings.compactMap { recording in
            guard let transcript = recording.normalizedTranscriptText else { return nil }
            let timestampText = TimestampFormatter.display(for: recording.timestamp)
            let durationText = TimeFormatter.display(for: recording.duration)
            return "[\(timestampText) · \(durationText)]\n\(transcript)"
        }
    }
}

private struct NarrationCoachSheet: View {
    @StateObject private var viewModel: NarrationCoachViewModel
    
    init(noteTitle: String, noteContent: String, onSummaryGenerated: ((String) -> Void)? = nil) {
        _viewModel = StateObject(wrappedValue: NarrationCoachViewModel(
            noteTitle: noteTitle,
            noteContent: noteContent,
            onSummaryGenerated: onSummaryGenerated
        ))
    }
    
    var body: some View {
        NarrationCoachView(viewModel: viewModel)
    }
}

// MARK: - Supporting Views

private struct RecordingAccessoryIcon: View {
    let isActive: Bool
    let count: Int
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
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
            
            if count > 1 {
                Text(count > 99 ? "99+" : "\(count)")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.accentColor)
                    )
                    .offset(x: 6, y: -6)
            }
        }
    }
}

private struct RecordingPreviewListPanel: View {
    let recordings: [Recording]
    let highlightedRecordingID: UUID?
    let currentlyPlayingID: UUID?
    let playAction: (Recording) -> Void
    let viewTranscriptAction: (Recording) -> Void
    let retryTranscriptionAction: (Recording) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("关联录音 (\(recordings.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            
            ForEach(recordings) { recording in
                RecordingPreviewRow(
                    recording: recording,
                    isHighlighted: highlightedRecordingID == recording.id,
                    isPlaying: currentlyPlayingID == recording.id,
                    playAction: { playAction(recording) },
                    viewTranscriptAction: { viewTranscriptAction(recording) },
                    retryTranscriptionAction: { retryTranscriptionAction(recording) }
                )
            }
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

private struct RecordingPreviewRow: View {
    let recording: Recording
    let isHighlighted: Bool
    let isPlaying: Bool
    let playAction: () -> Void
    let viewTranscriptAction: () -> Void
    let retryTranscriptionAction: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(TimestampFormatter.display(for: recording.timestamp))
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("时长 \(TimeFormatter.display(for: recording.duration))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                if let status = statusText {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                }
            }
            
            Spacer()
            
            transcriptControl
            
            Button(action: playAction) {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(isPlaying ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    isHighlighted
                    ? Color.accentColor.opacity(0.12)
                    : Color(UIColor.secondarySystemBackground)
                )
        )
        .contextMenu {
            Button("查看转写") {
                viewTranscriptAction()
            }
            .disabled(!recording.hasTranscript)
            
            Button("重新转写") {
                retryTranscriptionAction()
            }
            .disabled(!recording.canManualRetryTranscription)
        }
    }
    
    @ViewBuilder
    private var transcriptControl: some View {
        switch recording.transcriptionStatus {
        case .processing:
            ProgressView()
                .progressViewStyle(.circular)
                .frame(width: 32, height: 32)
        case .failed:
            Button(action: retryTranscriptionAction) {
                Image(systemName: "arrow.clockwise.circle")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("重新转写")
            .disabled(!recording.canManualRetryTranscription)
        case .completed:
            Button(action: viewTranscriptAction) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("查看转写")
        case .queued:
            if recording.hasTranscript {
                Button(action: viewTranscriptAction) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            } else if recording.isWaitingForScheduledRetry {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.orange)
                    .accessibilityLabel("等待自动重试")
            } else {
                Image(systemName: "hourglass")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("排队中")
            }
        case .idle:
            if recording.hasTranscript {
                Button(action: viewTranscriptAction) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "text.badge.plus")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("等待转写")
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

private struct MainThreadHintView: View {
    let insertAction: () -> Void
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "target")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .padding(10)
                .background(
                    Circle()
                        .fill(Color.accentColor.opacity(0.12))
                )
            
            VStack(alignment: .leading, spacing: 4) {
                Text("建议以 # 核心主线 开头")
                    .font(.headline)
                Text("第一段会被视为主线，AI 会优先保留并轻微润色。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Button("一键添加") {
                insertAction()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(UIColor.secondarySystemBackground))
        )
    }
}

private struct RewritePreviewSheet: View {
    let original: String
    let suggestion: String
    let confirmAction: () -> Void
    let cancelAction: () -> Void
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    rewriteSection(
                        title: "整理后的内容",
                        text: suggestion,
                        isPrimary: true
                    )
                    
                    rewriteSection(
                        title: "整理前的内容",
                        text: original,
                        isPrimary: false
                    )
                }
                .padding(.vertical, 24)
            }
            .padding(.horizontal, 20)
            .navigationTitle("AI 整理预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        cancelAction()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("替换") {
                        confirmAction()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
    
    @ViewBuilder
    private func rewriteSection(title: String, text: String, isPrimary: Bool) -> some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayText = trimmed.isEmpty ? "（空）" : trimmed
        
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(verbatim: displayText)
                .font(.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isPrimary ? Color(UIColor.systemBackground) : Color(UIColor.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(UIColor.separator), lineWidth: isPrimary ? 1 : 0)
        )
        .shadow(
            color: isPrimary ? Color.black.opacity(0.04) : Color.clear,
            radius: isPrimary ? 8 : 0,
            x: 0,
            y: isPrimary ? 4 : 0
        )
    }
}

