import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct RecordingInsightsSheet: View {
    let result: RecordingInsightsDisplayResult
    let dismissAction: () -> Void
    let saveAction: (RecordingInsightsDisplayResult) -> Void
    let clusterSelectionAction: (RecordingInsightsCluster, RecordingInsightsDisplayResult) -> Void
    
    @State private var showCopyToast = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    narrativeSection
                    
                    if !result.clusters.isEmpty {
                        clustersSection
                    }
                    
                    if let extras = result.additionalInsights, !extras.isEmpty {
                        additionalInsightsSection(extras)
                    }
                    
                    analysisMetaSection
                }
                .padding(20)
            }
            .navigationTitle("AI 洞察")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismissAction()
                    }
                }
                
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        copyInsights()
                        indicateCopied()
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                saveButton
            }
            .overlay(alignment: .bottom) {
                if showCopyToast {
                    copyToast
                }
            }
        }
    }
    
    private var narrativeSection: some View {
        SectionCard(title: "叙述总结") {
            VStack(alignment: .leading, spacing: 12) {
                Text(result.narrative)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineSpacing(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                if let reflection = result.reflectionPrompt, !reflection.isEmpty {
                    ReflectionTag(text: reflection)
                }
            }
        }
    }
    
    private var clustersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("聚类洞察")
                .font(.headline)
                .foregroundStyle(.secondary)
            
            VStack(spacing: 12) {
                ForEach(result.clusters) { cluster in
                    Button {
                        clusterSelectionAction(cluster, result)
                    } label: {
                        ClusterCard(cluster: cluster)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
    
    private func additionalInsightsSection(_ items: [String]) -> some View {
        SectionCard(title: "补充观察") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                        Text(item)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
    
    private var analysisMetaSection: some View {
        SectionCard(title: "分析范围") {
            VStack(alignment: .leading, spacing: 6) {
                metaRow(label: "纳入录音", value: "\(result.analyzedCount) 条")
                metaRow(label: "原始选择", value: "\(result.totalSelectedCount) 条")
                
                if let timeframe = result.timeframeDescription {
                    metaRow(label: "选择范围", value: timeframe)
                }
                
                if result.excludedCount > 0 {
                    Text("有 \(result.excludedCount) 条录音尚未完成精校转录，AI 暂无法分析。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
        }
    }
    
    private func metaRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .foregroundStyle(.primary)
        }
        .font(.subheadline)
    }
    
    private var saveButton: some View {
        HStack {
            Spacer()
            Button {
                saveAction(result)
            } label: {
                Label("保存到文本子页", systemImage: "doc.badge.plus")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.accentColor.opacity(0.7))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }
    
    private var copyToast: some View {
        Text("已复制到剪贴板")
            .font(.footnote)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
    
    private func copyInsights() {
        #if canImport(UIKit)
        UIPasteboard.general.string = insightsTextForCopy
        #endif
    }
    
    private func indicateCopied() {
        withAnimation {
            showCopyToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation {
                showCopyToast = false
            }
        }
    }
    
    private var insightsTextForCopy: String {
        var segments: [String] = []
        segments.append("【叙述总结】\n\(result.narrative)")
        
        if let reflection = result.reflectionPrompt, !reflection.isEmpty {
            segments.append("【反思提示】\n\(reflection)")
        }
        
        if !result.clusters.isEmpty {
            segments.append("【聚类洞察】")
            for cluster in result.clusters {
                var clusterLines: [String] = []
                clusterLines.append("〈\(cluster.title)〉")
                clusterLines.append(cluster.highlight)
                if let detail = cluster.detail {
                    clusterLines.append(detail)
                }
                if !cluster.recordingIDs.isEmpty {
                    let joinedIDs = cluster.recordingIDs.map { $0.uuidString }.joined(separator: ", ")
                    clusterLines.append("关联录音：\(joinedIDs)")
                }
                segments.append(clusterLines.joined(separator: "\n"))
            }
        }
        
        if let extras = result.additionalInsights, !extras.isEmpty {
            segments.append("【补充观察】")
            extras.forEach { segments.append("- \($0)") }
        }
        
        var footer: [String] = []
        footer.append("分析录音：\(result.analyzedCount)/\(result.totalSelectedCount)")
        if let timeframe = result.timeframeDescription {
            footer.append("选择范围：\(timeframe)")
        }
        segments.append(footer.joined(separator: " · "))
        
        return segments.joined(separator: "\n\n")
    }
}

private struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            content
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(UIColor.secondarySystemBackground))
        )
    }
}

private struct ReflectionTag: View {
    let text: String
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.footnote)
            Text(text)
                .font(.footnote)
                .multilineTextAlignment(.leading)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            Capsule()
                .fill(Color.accentColor.opacity(0.12))
        )
        .foregroundStyle(Color.accentColor)
    }
}

private struct ClusterCard: View {
    let cluster: RecordingInsightsCluster
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(cluster.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                
                Text(cluster.highlight)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                
                if let detail = cluster.detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                
                if !cluster.recordingIDs.isEmpty {
                    Text("关联录音 \(cluster.recordingIDs.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
            
            Spacer(minLength: 8)
            
            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(UIColor.secondarySystemBackground))
        )
    }
}
