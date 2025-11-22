import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct RecordingTranscriptSheet: View {
    let recording: Recording
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    @State private var isPolishing = false
    @State private var polishErrorMessage: String?
    @State private var showPolishErrorAlert = false
    @State private var editingTitleText = ""
    @FocusState private var isTitleFocused: Bool
    
    private let polishService = OpenAITranscriptPolishService()
    
    private var transcriptText: String? {
        recording.normalizedTranscriptText
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    metadataSection
                    transcriptSection
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onTapGesture {
                isTitleFocused = false
            }
            .navigationTitle("录音转写")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("复制") {
                        copyTranscript()
                    }
                    .disabled(transcriptText == nil)
                }
            }
        }
        .alert("润色失败", isPresented: $showPolishErrorAlert) {
            Button("好的", role: .cancel) { polishErrorMessage = nil }
        } message: {
            Text(polishErrorMessage ?? "请稍后再试。")
        }
        .onAppear {
            editingTitleText = recording.title ?? ""
        }
    }
    
    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("录音信息")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            // Title Editing Section
            TextField("输入标题", text: $editingTitleText)
                .font(.headline)
                .textFieldStyle(.plain)
                .focused($isTitleFocused)
                .submitLabel(.done)
                .onSubmit {
                    isTitleFocused = false
                }
                .onChange(of: isTitleFocused) { _, focused in
                    if !focused {
                        saveTitle()
                    }
                }
            
            // Timestamp (if title exists, show timestamp as secondary info)
            if recording.title?.isEmpty == false {
                Text(TimestampFormatter.display(for: recording.timestamp))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            Text("时长 \(TimeFormatter.display(for: recording.duration))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            if let status = statusDescription {
                Label(status.text, systemImage: status.symbol)
                    .font(.footnote)
                    .foregroundStyle(status.color)
            }
            
            if shouldShowPolishSection {
                Divider().padding(.vertical, 4)
                
                if isPolishing {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("润色中…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else if hasBeenPolished {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("已润色")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        polishTranscript()
                    } label: {
                        Label("润色文本", systemImage: "wand.and.stars")
                            .font(.subheadline.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.accentColor)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(UIColor.secondarySystemBackground))
        )
    }
    
    @ViewBuilder
    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("转写结果")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            if let transcriptText {
                Text(transcriptText)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(statusDescription?.text ?? "转写尚未完成。")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(UIColor.systemBackground))
                .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 6)
        )
    }
    
    private func copyTranscript() {
        guard let transcriptText else { return }
        #if canImport(UIKit)
        UIPasteboard.general.string = transcriptText
        #endif
    }
    
    private var statusDescription: (text: String, symbol: String, color: Color)? {
        switch recording.transcriptionStatus {
        case .completed:
            return ("转写完成", "checkmark.seal.fill", .green)
        case .processing:
            return ("转写中…", "clock.fill", .orange)
        case .failed:
            let message = recording.transcriptionErrorMessage ?? "转写失败"
            return (message, "exclamationmark.triangle.fill", .orange)
        case .queued:
            if recording.hasTranscript {
                return ("已缓存转写", "text.quote", .secondary)
            }
            if recording.isWaitingForScheduledRetry {
                let text = recording.queuedStatusDescription() ?? "等待自动重试"
                return (text, "clock.badge.exclamationmark", .orange)
            }
            return ("排队等待转写", "hourglass", .secondary)
        case .idle:
            return recording.hasTranscript ? ("已缓存转写", "text.quote", .secondary) : ("等待转写", "text.badge.plus", .secondary)
        }
    }
    
    private var hasBeenPolished: Bool {
        recording.polishedTranscriptText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
    
    private var shouldShowPolishSection: Bool {
        recording.transcriptText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
    
    private func polishTranscript() {
        guard let text = recording.transcriptText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            polishErrorMessage = "当前没有可润色的转写文本。"
            showPolishErrorAlert = true
            return
        }
        
        isPolishing = true
        Task {
            do {
                let result = try await polishService.polish(text: text)
                await MainActor.run {
                    recording.transcriptText = result.polishedText
                    recording.polishedTranscriptText = result.polishedText
                    if recording.title == nil || recording.title?.isEmpty == true {
                        recording.title = result.title
                    }
                    recording.transcriptUpdatedAt = Date()
                    try? modelContext.save()
                    isPolishing = false
                }
            } catch {
                await MainActor.run {
                    polishErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    showPolishErrorAlert = true
                    isPolishing = false
                }
            }
        }
    }
    
    private func saveTitle() {
        let trimmed = editingTitleText.trimmingCharacters(in: .whitespacesAndNewlines)
        recording.title = trimmed.isEmpty ? nil : trimmed
        try? modelContext.save()
    }
}

