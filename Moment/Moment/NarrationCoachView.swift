import SwiftUI

struct NarrationCoachView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: NarrationCoachViewModel
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                promptCard
                transcriptSection
                summarySection
                Spacer(minLength: 12)
                controlButton
            }
            .padding(20)
            .navigationTitle("口播教练")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        viewModel.tearDown()
                        dismiss()
                    }
                }
            }
        }
        .alert("无法继续练习", isPresented: $viewModel.showErrorAlert, actions: {
            Button("好的", role: .cancel) { }
        }, message: {
            Text(viewModel.errorMessage ?? "请稍后再试。")
        })
        .overlay(toastOverlay, alignment: .top)
        .onDisappear {
            viewModel.tearDown()
        }
    }
    
    private var promptCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(viewModel.isRecording ? Color.accentColor : Color.secondary)
                    .frame(width: 10, height: 10)
                Text(viewModel.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            
            Text("下一句提示")
                .font(.footnote)
                .foregroundStyle(.secondary)
            
            Text(viewModel.currentPrompt)
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(UIColor.secondarySystemBackground))
        )
    }
    
    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("口播记录")
                    .font(.headline)
                Spacer()
                if viewModel.isRecording {
                    Text("实时识别中…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            let entries = Array(viewModel.transcriptEntries.suffix(4))
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.text)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(UIColor.systemBackground))
                        .shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 2)
                )
            }
            
            if !viewModel.transcriptPreview.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .progressViewStyle(.circular)
                    Text(viewModel.transcriptPreview)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            
            if entries.isEmpty && viewModel.transcriptPreview.isEmpty {
                Text("每次暂停讲话都会自动生成一条文本，便于回顾。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(UIColor.systemBackground))
                    )
            }
        }
    }
    
    @ViewBuilder
    private var summarySection: some View {
        if let summary = viewModel.summaryText, !summary.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("本次练习总结")
                        .font(.headline)
                    Spacer()
                    Button {
                        viewModel.copySummaryToPasteboard()
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                }
                
                ScrollView {
                    Text(summary)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(UIColor.secondarySystemBackground))
            )
        }
    }
    
    private var controlButton: some View {
        Button(action: viewModel.toggleSession) {
            ZStack {
                Circle()
                    .fill(controlButtonBackground)
                    .frame(width: 120, height: 120)
                    .shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: 6)
                
                VStack(spacing: 8) {
                    Image(systemName: viewModel.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 30, weight: .bold))
                    Text(viewModel.isRecording ? "结束练习" : "开始练习")
                        .font(.headline)
                }
                .foregroundStyle(controlButtonForeground)
            }
        }
        .disabled(viewModel.state == .summarizing)
        .opacity(viewModel.state == .summarizing ? 0.6 : 1)
        .padding(.bottom, 12)
    }
    
    private var controlButtonBackground: LinearGradient {
        if viewModel.isRecording {
            return LinearGradient(
                colors: [Color.accentColor.opacity(0.9), Color.accentColor],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            return LinearGradient(
                colors: [Color(UIColor.secondarySystemBackground), Color(UIColor.systemBackground)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
    
    private var controlButtonForeground: Color {
        viewModel.isRecording ? .white : .primary
    }
    
    @ViewBuilder
    private var toastOverlay: some View {
        if viewModel.isCopyToastVisible {
            Text("已复制到剪贴板")
                .font(.footnote)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.7))
                )
                .foregroundStyle(.white)
                .padding(.top, 16)
        }
    }
}


