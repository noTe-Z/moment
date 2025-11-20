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
                    }
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear {
            loadAssociatedRecordingsIfNeeded()
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
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            rewriteErrorMessage = "笔记内容为空，无法整理。"
            showRewriteError = true
            return
        }
        
        if isRewriting {
            return
        }
        
        isRewriting = true
        rewriteSourceSnapshot = content
        let requestText = trimmed
        
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
                    playAction: { playAction(recording) }
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
    
    var body: some View {
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
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("差异对比")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        RewriteDiffView(original: original, suggestion: suggestion)
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(UIColor.systemBackground))
                            .shadow(color: Color.black.opacity(0.06), radius: 10, x: 0, y: 4)
                    )
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("AI 整理后的段落")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(suggestion)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(UIColor.systemBackground))
                            .shadow(color: Color.black.opacity(0.06), radius: 10, x: 0, y: 4)
                    )
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("原始内容")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(original.isEmpty ? "（空）" : original)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(UIColor.secondarySystemBackground))
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
}

private struct RewriteDiffView: View {
    let original: String
    let suggestion: String
    
    private var sections: [DiffSection] {
        StructuredDiffBuilder.buildSections(original: original, updated: suggestion)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if sections.isEmpty {
                Text("内容完全一致，无需更改。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(UIColor.secondarySystemBackground))
                    )
            } else {
                ForEach(sections) { section in
                    DiffSectionView(section: section)
                }
            }
        }
    }
}

private struct DiffSectionView: View {
    let section: DiffSection
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(section.displayTitle)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Text(section.change.label)
                    .font(.caption)
                    .foregroundStyle(section.change.accentColor)
            }
            .foregroundStyle(section.change.accentColor)
            
            if section.change == .unchanged {
                Text("该部分没有变化。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(UIColor.secondarySystemBackground))
                    )
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(section.rows) { row in
                        DiffRowView(row: row)
                    }
                }
            }
        }
    }
}

private struct DiffRowView: View {
    let row: DiffRow
    
    @ViewBuilder
    var body: some View {
        switch row {
        case .line(id: _, text: let text, change: let change):
            DiffLineRow(text: text, change: change)
        case .replacement(id: _, old: let oldValue, new: let newValue):
            ReplacementDiffRow(oldText: oldValue, newText: newValue)
        case .contextSummary(id: _, count: let count):
            ContextSummaryRow(count: count)
        }
    }
}

private struct DiffLineRow: View {
    let text: String
    let change: DiffChange
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(change.symbol)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(change.symbolColor)
                .frame(width: 14, alignment: .leading)
            Text(text.isEmpty ? " " : text)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(change.backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ReplacementDiffRow: View {
    let oldText: String
    let newText: String
    
    private var inlineDiff: InlineDiffResult {
        WordDiffBuilder.build(old: oldText, new: newText)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            InlineDiffLine(prefix: "-", tokens: inlineDiff.oldTokens, mode: .deletion)
            InlineDiffLine(prefix: "+", tokens: inlineDiff.newTokens, mode: .addition)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(UIColor.secondarySystemBackground))
        )
    }
}

private struct InlineDiffLine: View {
    enum Mode {
        case addition
        case deletion
    }
    
    let prefix: String
    let tokens: [InlineToken]
    let mode: Mode
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(prefix)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(mode == .addition ? Color.green : Color.red)
                .frame(width: 14, alignment: .leading)
            Text(attributedString)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    
    private var attributedString: AttributedString {
        var result = AttributedString()
        for token in tokens {
            var chunk = AttributedString(token.text)
            switch token.change {
            case .same:
                chunk.foregroundColor = .primary
            case .addition:
                chunk.foregroundColor = .green
                chunk.font = .body.bold()
            case .deletion:
                chunk.foregroundColor = .red
                chunk.strikethroughStyle = .single
            case .neutral:
                chunk.foregroundColor = .secondary
            }
            result.append(chunk)
        }
        return result
    }
}

private struct ContextSummaryRow: View {
    let count: Int
    
    var body: some View {
        HStack(spacing: 8) {
            Text("…")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("\(count) 行完全一致")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(UIColor.secondarySystemBackground))
        )
    }
}

private struct DiffSection: Identifiable {
    let id: String
    let title: String?
    let change: SectionChange
    let rows: [DiffRow]
    
    var displayTitle: String {
        title ?? "正文"
    }
}

private enum SectionChange: Equatable {
    case unchanged
    case modified
    case added
    case removed
    
    var label: String {
        switch self {
        case .unchanged:
            return "未变化"
        case .modified:
            return "有更新"
        case .added:
            return "新增"
        case .removed:
            return "已删除"
        }
    }
    
    var accentColor: Color {
        switch self {
        case .unchanged:
            return .secondary
        case .modified:
            return .blue
        case .added:
            return .green
        case .removed:
            return .red
        }
    }
}

private enum DiffRow: Identifiable {
    case line(id: UUID = UUID(), text: String, change: DiffChange)
    case replacement(id: UUID = UUID(), old: String, new: String)
    case contextSummary(id: UUID = UUID(), count: Int)
    
    var id: UUID {
        switch self {
        case .line(id: let id, text: _, change: _):
            return id
        case .replacement(id: let id, old: _, new: _):
            return id
        case .contextSummary(id: let id, count: _):
            return id
        }
    }
}

private enum DiffChange {
    case same
    case addition
    case deletion
    
    var symbol: String {
        switch self {
        case .addition:
            return "+"
        case .deletion:
            return "-"
        case .same:
            return " "
        }
    }
    
    var symbolColor: Color {
        switch self {
        case .addition:
            return Color.green
        case .deletion:
            return Color.red
        case .same:
            return Color.secondary
        }
    }
    
    var backgroundColor: Color {
        switch self {
        case .addition:
            return Color.green.opacity(0.12)
        case .deletion:
            return Color.red.opacity(0.12)
        case .same:
            return Color.clear
        }
    }
}

private struct NoteSection {
    let key: String
    let title: String?
    let lines: [String]
}

private enum StructuredDiffBuilder {
    static func buildSections(original: String, updated: String) -> [DiffSection] {
        let sourceSections = NoteSectionParser.parse(original)
        let updatedSections = NoteSectionParser.parse(updated)
        
        if sourceSections.isEmpty && updatedSections.isEmpty {
            return []
        }
        
        let sourceMap = Dictionary(uniqueKeysWithValues: sourceSections.map { ($0.key, $0) })
        let updatedMap = Dictionary(uniqueKeysWithValues: updatedSections.map { ($0.key, $0) })
        var orderedKeys: [String] = []
        
        for section in sourceSections where !orderedKeys.contains(section.key) {
            orderedKeys.append(section.key)
        }
        for section in updatedSections where !orderedKeys.contains(section.key) {
            orderedKeys.append(section.key)
        }
        
        return orderedKeys.compactMap { key in
            let oldSection = sourceMap[key]
            let newSection = updatedMap[key]
            let title = newSection?.title ?? oldSection?.title
            
            switch (oldSection, newSection) {
            case (nil, nil):
                return nil
            case (nil, let new?):
                let rows = new.lines.map { DiffRow.line(text: $0, change: .addition) }
                return DiffSection(id: key, title: title, change: .added, rows: rows)
            case (let old?, nil):
                let rows = old.lines.map { DiffRow.line(text: $0, change: .deletion) }
                return DiffSection(id: key, title: title, change: .removed, rows: rows)
            case (let old?, let new?):
                let operations = LineDiffBuilder.operations(oldLines: old.lines, newLines: new.lines)
                let rows = DiffRowBuilder.rows(from: operations)
                let change: SectionChange = rows.contains(where: { $0.representsChange }) ? .modified : .unchanged
                return DiffSection(id: key, title: title, change: change, rows: rows)
            }
        }
    }
}

private enum DiffRowBuilder {
    static func rows(from operations: [LineOperation], collapseThreshold: Int = 4) -> [DiffRow] {
        guard !operations.isEmpty else { return [] }
        
        var rows: [DiffRow] = []
        var index = 0
        
        while index < operations.count {
            let op = operations[index]
            if case .deletion(let oldText) = op,
               index + 1 < operations.count,
               case .addition(let newText) = operations[index + 1],
               WordDiffBuilder.similarityScore(oldText, newText) >= 0.35 {
                rows.append(.replacement(old: oldText, new: newText))
                index += 2
            } else if case .addition(let newText) = op,
                      index + 1 < operations.count,
                      case .deletion(let oldText) = operations[index + 1],
                      WordDiffBuilder.similarityScore(oldText, newText) >= 0.35 {
                rows.append(.replacement(old: oldText, new: newText))
                index += 2
            } else {
                rows.append(.line(text: op.text, change: op.change))
                index += 1
            }
        }
        
        return collapse(rows, threshold: collapseThreshold)
    }
    
    private static func collapse(_ rows: [DiffRow], threshold: Int) -> [DiffRow] {
        var result: [DiffRow] = []
        var buffer: [DiffRow] = []
        
        func flushBuffer() {
            guard !buffer.isEmpty else { return }
            if buffer.count >= threshold {
                if let first = buffer.first {
                    result.append(first)
                }
                if buffer.count > 2 {
                    let collapsedCount = buffer.count - 2
                    result.append(.contextSummary(count: collapsedCount))
                }
                if buffer.count > 1, let last = buffer.last {
                    result.append(last)
                }
            } else {
                result.append(contentsOf: buffer)
            }
            buffer.removeAll()
        }
        
        for row in rows {
            if case .line(id: _, text: _, change: let change) = row, change == .same {
                buffer.append(row)
            } else {
                flushBuffer()
                result.append(row)
            }
        }
        flushBuffer()
        return result
    }
}

private enum LineDiffBuilder {
    static func operations(oldLines: [String], newLines: [String]) -> [LineOperation] {
        if oldLines.isEmpty, newLines.isEmpty { return [] }
        if oldLines.isEmpty { return newLines.map { .addition($0) } }
        if newLines.isEmpty { return oldLines.map { .deletion($0) } }
        
        let matrix = lcsMatrix(oldLines, newLines)
        var i = oldLines.count
        var j = newLines.count
        var result: [LineOperation] = []
        
        while i > 0 && j > 0 {
            if oldLines[i - 1] == newLines[j - 1] {
                result.append(.same(oldLines[i - 1]))
                i -= 1
                j -= 1
            } else if matrix[i - 1][j] >= matrix[i][j - 1] {
                result.append(.deletion(oldLines[i - 1]))
                i -= 1
            } else {
                result.append(.addition(newLines[j - 1]))
                j -= 1
            }
        }
        
        while i > 0 {
            result.append(.deletion(oldLines[i - 1]))
            i -= 1
        }
        
        while j > 0 {
            result.append(.addition(newLines[j - 1]))
            j -= 1
        }
        
        return result.reversed()
    }
    
    private static func lcsMatrix(_ a: [String], _ b: [String]) -> [[Int]] {
        var matrix = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        
        for i in 1...a.count {
            for j in 1...b.count {
                if a[i - 1] == b[j - 1] {
                    matrix[i][j] = matrix[i - 1][j - 1] + 1
                } else {
                    matrix[i][j] = max(matrix[i - 1][j], matrix[i][j - 1])
                }
            }
        }
        
        return matrix
    }
}

private enum NoteSectionParser {
    static func parse(_ text: String) -> [NoteSection] {
        var sections: [NoteSection] = []
        var currentLines: [String] = []
        var currentTitle: String?
        var usedKeys = Set<String>()
        
        func appendSection(force: Bool = false) {
            let hasContent = currentLines.contains { !$0.isEmpty }
            guard hasContent || force else { return }
            let baseKey = (currentTitle?.lowercased() ?? "body")
            let key = uniqueKey(base: baseKey, usedKeys: &usedKeys)
            sections.append(NoteSection(key: key, title: currentTitle, lines: currentLines))
            currentLines = []
        }
        
        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let heading = headingTitle(from: trimmed) {
                appendSection(force: currentTitle != nil)
                currentTitle = heading
                currentLines = []
            } else {
                currentLines.append(line)
            }
        }
        
        appendSection(force: currentTitle != nil || !currentLines.isEmpty)
        return sections
    }
    
    private static func headingTitle(from line: String) -> String? {
        guard !line.isEmpty else { return nil }
        if line.hasPrefix("#") {
            return line.replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
        }
        return nil
    }
    
    private static func uniqueKey(base: String, usedKeys: inout Set<String>) -> String {
        var key = base
        var counter = 2
        while usedKeys.contains(key) {
            key = "\(base)#\(counter)"
            counter += 1
        }
        usedKeys.insert(key)
        return key
    }
}

private enum WordDiffBuilder {
    static func build(old: String, new: String) -> InlineDiffResult {
        let oldTokens = tokenize(old)
        let newTokens = tokenize(new)
        
        let oldWords = oldTokens.enumerated().compactMap { $0.element.isWord ? (index: $0.offset, text: normalized($0.element.text)) : nil }
        let newWords = newTokens.enumerated().compactMap { $0.element.isWord ? (index: $0.offset, text: normalized($0.element.text)) : nil }
        
        let (oldMatches, newMatches) = lcsMatches(oldWords.map(\.text), newWords.map(\.text))
        
        var inlineOld: [InlineToken] = []
        var inlineNew: [InlineToken] = []
        var oldCursor = 0
        var newCursor = 0
        
        for token in oldTokens {
            if token.isWord {
                let matched = oldMatches[oldCursor]
                inlineOld.append(InlineToken(text: token.text, change: matched ? .same : .deletion))
                oldCursor += 1
            } else {
                inlineOld.append(InlineToken(text: token.text, change: .neutral))
            }
        }
        
        for token in newTokens {
            if token.isWord {
                let matched = newMatches[newCursor]
                inlineNew.append(InlineToken(text: token.text, change: matched ? .same : .addition))
                newCursor += 1
            } else {
                inlineNew.append(InlineToken(text: token.text, change: .neutral))
            }
        }
        
        return InlineDiffResult(oldTokens: inlineOld, newTokens: inlineNew)
    }
    
    static func similarityScore(_ old: String, _ new: String) -> Double {
        let oldTokens = tokenize(old).filter(\.isWord).map { normalized($0.text) }
        let newTokens = tokenize(new).filter(\.isWord).map { normalized($0.text) }
        guard !oldTokens.isEmpty || !newTokens.isEmpty else { return 0 }
        let matrix = lcsMatrix(oldTokens, newTokens)
        let lcsLength = matrix[oldTokens.count][newTokens.count]
        let denominator = max(oldTokens.count, newTokens.count)
        guard denominator > 0 else { return 0 }
        return Double(lcsLength) / Double(denominator)
    }
    
    private static func tokenize(_ text: String) -> [WordToken] {
        var tokens: [WordToken] = []
        var currentWord = ""
        var currentSpace = ""
        
        for char in text {
            if char.isWhitespace {
                if !currentWord.isEmpty {
                    tokens.append(WordToken(text: currentWord, isWord: true))
                    currentWord = ""
                }
                currentSpace.append(char)
            } else {
                if !currentSpace.isEmpty {
                    tokens.append(WordToken(text: currentSpace, isWord: false))
                    currentSpace = ""
                }
                currentWord.append(char)
            }
        }
        
        if !currentWord.isEmpty {
            tokens.append(WordToken(text: currentWord, isWord: true))
        }
        if !currentSpace.isEmpty {
            tokens.append(WordToken(text: currentSpace, isWord: false))
        }
        return tokens
    }
    
    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }
    
    private static func lcsMatches(_ a: [String], _ b: [String]) -> ([Bool], [Bool]) {
        let matrix = lcsMatrix(a, b)
        var i = a.count
        var j = b.count
        var aMatches = Array(repeating: false, count: a.count)
        var bMatches = Array(repeating: false, count: b.count)
        
        while i > 0 && j > 0 {
            if a[i - 1] == b[j - 1] {
                aMatches[i - 1] = true
                bMatches[j - 1] = true
                i -= 1
                j -= 1
            } else if matrix[i - 1][j] >= matrix[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        
        return (aMatches, bMatches)
    }
    
    private static func lcsMatrix(_ a: [String], _ b: [String]) -> [[Int]] {
        var matrix = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        
        for i in 1...a.count {
            for j in 1...b.count {
                if a[i - 1] == b[j - 1] {
                    matrix[i][j] = matrix[i - 1][j - 1] + 1
                } else {
                    matrix[i][j] = max(matrix[i - 1][j], matrix[i][j - 1])
                }
            }
        }
        
        return matrix
    }
}

private struct InlineDiffResult {
    let oldTokens: [InlineToken]
    let newTokens: [InlineToken]
}

private struct WordToken {
    let text: String
    let isWord: Bool
}

private struct InlineToken: Identifiable {
    enum Change {
        case same
        case addition
        case deletion
        case neutral
    }
    
    let id = UUID()
    let text: String
    let change: Change
}

private extension DiffRow {
    var representsChange: Bool {
        switch self {
        case .line(id: _, text: _, change: let change):
            return change != .same
        case .replacement:
            return true
        case .contextSummary:
            return false
        }
    }
}

private enum LineOperation {
    case same(String)
    case addition(String)
    case deletion(String)
    
    var text: String {
        switch self {
        case .same(let value), .addition(let value), .deletion(let value):
            return value
        }
    }
    
    var change: DiffChange {
        switch self {
        case .same:
            return .same
        case .addition:
            return .addition
        case .deletion:
            return .deletion
        }
    }
}


