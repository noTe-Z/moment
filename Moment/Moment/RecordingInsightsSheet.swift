import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct RecordingInsightsSheet: View {
    let result: RecordingInsightsDisplayResult
    let dismissAction: () -> Void
    
    @State private var showCopyToast = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    summarySection
                    
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
            .overlay(alignment: .bottom) {
                if showCopyToast {
                    copyToast
                }
            }
        }
    }
    
    private var summarySection: some View {
        SectionCard(title: "整体总结") {
            Text(result.summary)
                .font(.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    
    private var clustersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("聚类洞察")
                .font(.headline)
                .foregroundStyle(.secondary)
            
            VStack(spacing: 12) {
                ForEach(result.clusters) { cluster in
                    SectionCard(title: cluster.title) {
                        VStack(alignment: .leading, spacing: 8) {
                            if let summary = cluster.summary, !summary.isEmpty {
                                Text(summary)
                                    .foregroundStyle(.primary)
                            }
                            
                            if let keyPoints = cluster.keyPoints, !keyPoints.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(keyPoints, id: \.self) { point in
                                        HStack(alignment: .top, spacing: 6) {
                                            Text("•")
                                            Text(point)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                    }
                                }
                            }
                            
                            if let emotions = cluster.sharedEmotions, !emotions.isEmpty {
                                Text("情绪：\(emotions.joined(separator: "、"))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
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
        segments.append("【整体总结】\n\(result.summary)")
        
        if !result.clusters.isEmpty {
            segments.append("【聚类洞察】")
            for cluster in result.clusters {
                var clusterLines: [String] = []
                clusterLines.append("〈\(cluster.title)〉")
                if let summary = cluster.summary {
                    clusterLines.append(summary)
                }
                if let keyPoints = cluster.keyPoints {
                    keyPoints.forEach { clusterLines.append("- \($0)") }
                }
                if let emotions = cluster.sharedEmotions, !emotions.isEmpty {
                    clusterLines.append("情绪：\(emotions.joined(separator: "、"))")
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

