import Foundation

struct RecordingInsightsResponse: Decodable {
    let summary: String
    let clusters: [RecordingInsightsCluster]
    let additionalInsights: [String]?
    
    private enum CodingKeys: String, CodingKey {
        case summary
        case clusters
        case additionalInsights = "additional_insights"
    }
    
    init(summary: String, clusters: [RecordingInsightsCluster], additionalInsights: [String]?) {
        self.summary = summary
        self.clusters = clusters
        self.additionalInsights = additionalInsights
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let summary = try container.decode(String.self, forKey: .summary)
        let clusters = try container.decodeIfPresent([RecordingInsightsCluster].self, forKey: .clusters) ?? []
        let additionalInsights = try container.decodeIfPresent([String].self, forKey: .additionalInsights)
        self.init(summary: summary, clusters: clusters, additionalInsights: additionalInsights)
    }
}

struct RecordingInsightsCluster: Decodable, Identifiable {
    let title: String
    let summary: String?
    let keyPoints: [String]?
    let sharedEmotions: [String]?
    
    var id: String { title }
    
    private enum CodingKeys: String, CodingKey {
        case title
        case summary
        case keyPoints = "key_points"
        case sharedEmotions = "shared_emotions"
    }
}

struct RecordingInsightsDisplayResult: Identifiable {
    let id = UUID()
    let summary: String
    let clusters: [RecordingInsightsCluster]
    let additionalInsights: [String]?
    let analyzedCount: Int
    let totalSelectedCount: Int
    let timeframeDescription: String?
    
    var excludedCount: Int {
        max(totalSelectedCount - analyzedCount, 0)
    }
}

