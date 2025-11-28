import Foundation

struct RecordingInsightsResponse: Decodable {
    let narrative: String
    let clusters: [RecordingInsightsCluster]
    let reflectionPrompt: String?
    let additionalInsights: [String]?
    
    private enum CodingKeys: String, CodingKey {
        case narrative
        case clusters
        case reflectionPrompt = "reflection_prompt"
        case additionalInsights = "additional_insights"
    }
    
    init(
        narrative: String,
        clusters: [RecordingInsightsCluster],
        reflectionPrompt: String?,
        additionalInsights: [String]?
    ) {
        self.narrative = narrative
        self.clusters = clusters
        self.reflectionPrompt = reflectionPrompt
        self.additionalInsights = additionalInsights
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let narrative = try container.decode(String.self, forKey: .narrative)
        let clusters = try container.decodeIfPresent([RecordingInsightsCluster].self, forKey: .clusters) ?? []
        let reflectionPrompt = try container.decodeIfPresent(String.self, forKey: .reflectionPrompt)
        let additionalInsights = try container.decodeIfPresent([String].self, forKey: .additionalInsights)
        self.init(
            narrative: narrative,
            clusters: clusters,
            reflectionPrompt: reflectionPrompt,
            additionalInsights: additionalInsights
        )
    }
}

struct RecordingInsightsCluster: Decodable, Identifiable {
    let id = UUID()
    let title: String
    let highlight: String
    let detail: String?
    let recordingIDs: [UUID]
    
    private enum CodingKeys: String, CodingKey {
        case title
        case highlight
        case detail
        case recordingIDs = "recording_ids"
    }
    
    init(title: String, highlight: String, detail: String?, recordingIDs: [UUID]) {
        self.title = title
        self.highlight = highlight
        self.detail = detail
        self.recordingIDs = recordingIDs
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let title = try container.decode(String.self, forKey: .title)
        let rawHighlight = Self.normalizedText(try container.decodeIfPresent(String.self, forKey: .highlight))
        let detail = Self.normalizedText(try container.decodeIfPresent(String.self, forKey: .detail))
        let rawIDs = try container.decodeIfPresent([String].self, forKey: .recordingIDs) ?? []
        let parsedIDs = rawIDs.compactMap(UUID.init(uuidString:))
        let highlight = rawHighlight ?? detail ?? title
        self.init(title: title, highlight: highlight, detail: detail, recordingIDs: parsedIDs)
    }
    
    // Legacy compatibility for existing UI; prefer using `highlight` / `detail`.
    var summary: String? { detail ?? highlight }
    var keyPoints: [String]? { nil }
    var sharedEmotions: [String]? { nil }
    
    private static func normalizedText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct RecordingInsightsDisplayResult: Identifiable {
    let id = UUID()
    let narrative: String
    let reflectionPrompt: String?
    let clusters: [RecordingInsightsCluster]
    let additionalInsights: [String]?
    let analyzedCount: Int
    let totalSelectedCount: Int
    let timeframeDescription: String?
    
    var excludedCount: Int {
        max(totalSelectedCount - analyzedCount, 0)
    }
    
    var summary: String { narrative }
}

