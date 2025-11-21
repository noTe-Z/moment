import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct RecordingTranscriptSheet: View {
    let recording: Recording
    @Environment(\.dismiss) private var dismiss
    
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
    }
    
    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("录音信息")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(TimestampFormatter.display(for: recording.timestamp))
                .font(.headline)
            Text("时长 \(TimeFormatter.display(for: recording.duration))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            if let status = statusDescription {
                Label(status.text, systemImage: status.symbol)
                    .font(.footnote)
                    .foregroundStyle(status.color)
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
}

