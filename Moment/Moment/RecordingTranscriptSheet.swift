import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct RecordingTranscriptSheet: View {
    let recording: Recording
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    @State private var editingTitleText = ""
    @State private var isPolishing = false
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
        .onAppear {
            editingTitleText = recording.title ?? ""
        }
        .onChange(of: recording.title) { _, newTitle in
            if !isTitleFocused {
                editingTitleText = newTitle ?? ""
            }
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
            
            if hasBeenPolished {
                Divider().padding(.vertical, 4)
                
                Label("文本已润色", systemImage: "wand.and.stars")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if canShowManualPolishControls {
                Divider().padding(.vertical, 4)
                
                if isPolishing {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("润色中…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        polishTranscript()
                    } label: {
                        Label(polishButtonLabel, systemImage: "wand.and.stars")
                            .font(.subheadline.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.accentColor)
                    .disabled(transcriptText == nil)
                }
                
                if let polishErrorDisplayText {
                    Text(polishErrorDisplayText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.top, 2)
                } else if recording.polishAttempted {
                    Text("若润色未生效，请开启 VPN 后再试。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
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
                Text(verbatim: transcriptText)
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
        recording.hasPolishedTranscript
    }
    
    private var canShowManualPolishControls: Bool {
        recording.needsManualPolish
    }
    
    private var polishButtonLabel: String {
        recording.polishAttempted ? "重新润色" : "润色文本"
    }
    
    private var polishErrorDisplayText: String? {
        guard let message = recording.polishErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty else {
            return nil
        }
        return message
    }
    
    private func saveTitle() {
        let trimmed = editingTitleText.trimmingCharacters(in: .whitespacesAndNewlines)
        recording.title = trimmed.isEmpty ? nil : trimmed
        try? modelContext.save()
    }
    
    private func polishTranscript() {
        guard let rawText = recording.transcriptText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawText.isEmpty else {
            return
        }
        
        isPolishing = true
        Task {
            await MainActor.run {
                recording.polishAttempted = true
                recording.polishErrorMessage = nil
                try? modelContext.save()
            }
            
            do {
                let result = try await polishService.polish(text: rawText)
                await MainActor.run {
                    recording.polishedTranscriptText = result.polishedText
                    recording.polishErrorMessage = nil
                    recording.polishAttempted = true
                    
                    if let generatedTitle = result.title,
                       (recording.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                        recording.title = generatedTitle
                        editingTitleText = generatedTitle
                    }
                    
                    recording.transcriptUpdatedAt = Date()
                    try? modelContext.save()
                    isPolishing = false
                }
            } catch {
                await MainActor.run {
                    recording.polishAttempted = true
                    recording.polishErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    try? modelContext.save()
                    isPolishing = false
                }
            }
        }
    }
}

