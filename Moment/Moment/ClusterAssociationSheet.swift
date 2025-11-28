import SwiftUI

struct ClusterAssociationSheet: View {
    let context: ClusterSaveContext
    let notes: [TextNote]
    let isSaving: Bool
    let selectAction: (TextNote) -> Void
    let createAction: () -> Void
    let saveFullAction: () -> Void
    let cancelAction: () -> Void
    
    var body: some View {
        List {
            Section("聚类洞察") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(context.cluster.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(context.cluster.highlight)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineSpacing(4)
                    if let detail = context.cluster.detail {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let timeframe = context.result.timeframeDescription {
                        Text("来源：\(timeframe)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !context.cluster.recordingIDs.isEmpty {
                        Text("关联录音 \(context.cluster.recordingIDs.count)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
            }
            
            Section("保存到已有文档") {
                if notes.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("暂时没有文本文档")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("可以先创建一个文档，再继续落地此聚类洞察。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                } else {
                    ForEach(notes) { note in
                        Button {
                            selectAction(note)
                        } label: {
                            HStack(spacing: 12) {
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
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .disabled(isSaving)
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
            VStack(spacing: 8) {
                Button {
                    createAction()
                } label: {
                    Label("新建文本文档保存此聚类", systemImage: "square.and.pencil")
                        .font(.headline)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
                
                Button {
                    saveFullAction()
                } label: {
                    Text("改为保存整篇 AI 洞察")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(Color.secondary)
                .disabled(isSaving)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
        }
        .navigationTitle("保存聚类洞察")
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
