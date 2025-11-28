import SwiftUI

struct InsightsSaveDestinationSheet: View {
    let result: RecordingInsightsDisplayResult
    let notes: [TextNote]
    let isSaving: Bool
    let selectAction: (TextNote) -> Void
    let createAction: () -> Void
    let cancelAction: () -> Void
    
    var body: some View {
        List {
            Section("洞察概览") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("叙述 + \(result.clusters.count) 个聚类")
                        .font(.headline)
                    Text("涵盖 \(result.analyzedCount) 条录音的精校转录")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    if let timeframe = result.timeframeDescription {
                        Text("范围：\(timeframe)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            
            Section("选择文本文档") {
                if notes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("暂时没有文本文档")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("可以新建一个文档来存放本周的 AI 洞察。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                } else {
                    ForEach(notes) { note in
                        Button {
                            selectAction(note)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(note.title.isEmpty ? "无标题文档" : note.title)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text("更新于 \(TimestampFormatter.display(for: note.updatedAt))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.footnote)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if isSaving {
                ProgressView("保存中…")
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .disabled(isSaving)
        .safeAreaInset(edge: .bottom) {
            Button {
                createAction()
            } label: {
                Label("新建文本文档并保存", systemImage: "square.and.pencil")
                    .font(.headline)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .navigationTitle("保存到文本子页")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("返回") {
                    cancelAction()
                }
                .disabled(isSaving)
            }
        }
    }
}

