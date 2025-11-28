import Foundation

struct RecordingInsightsService {
    private let configuration = Configuration()
    
    enum InsightsError: LocalizedError {
        case missingAPIKey
        case requestFailed(String)
        case invalidResponse(String)
        case emptyMessage
        
        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "未找到 OpenAI API Key，请在 Scheme 或 Build Settings 中配置 OPENAI_API_KEY。"
            case .requestFailed(let message):
                return "AI 洞察请求失败：\(message)"
            case .invalidResponse(let message):
                return "AI 响应解析失败：\(message)"
            case .emptyMessage:
                return "AI 返回的内容为空，请稍后重试。"
            }
        }
    }
    
    private enum Constants {
        static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
        static let model = "gpt-4o"
        static let systemPrompt = """
你是一位个人知识教练。你会分析用户在一周内录制的多条语音转录，帮助他们总结关键信息、找出模式、以及情绪或动机的变化。

请遵循以下要求：
1. 只依据提供的转录内容。不要猜测外部信息。
2. 先整体阅读全部输入，再进行归纳。
3. 先写一段连续的叙述（2-4 段），串联用户本周的主要思考、反复出现的情绪或矛盾，并可在结尾抛出一个关键问题/反思句。
4. 然后列出几个聚类卡片，每个卡片 1-2 句高亮描述，加上可选的进一步说明。
5. 输出 JSON，结构如下：
{
  "narrative": "段落化总结，描述主题、冲突、反复出现的情绪，最好在结尾抛出问题或反思句。",
  "reflection_prompt": "可选：一句点明核心矛盾或需要自问的问题。",
  "clusters": [
    {
      "title": "聚类标题，突出主题/矛盾/情绪",
      "highlight": "1-2 句最重要的洞察或提醒，避免重复 narrative。",
      "detail": "可选：补充背景、冲突或建议，用 2-3 句话以内。",
      "recording_ids": ["b8c8...", "..."] // 来自输入 JSON 中的 recordings[*].id
    }
  ],
  "additional_insights": ["可选：跨聚类的趋势、建议或风险，保持一句一条。"]
}
6. 如果无法形成聚类，可以返回空数组，但 narrative 仍需完整。
7. 使用与输入相同的语言（通常为中文）。
8. `recording_ids` 必须引用输入 JSON 中的 recordings[*].id；若聚类只与整体趋势相关，可返回空数组，但不要伪造 ID。
"""
    }
    
    func generateInsights(using payload: RecordingInsightsPayload) async throws -> RecordingInsightsResponse {
        let apiKey = OpenAIRewriteService.readAPIKey(for: "OPENAI_API_KEY")
        guard !apiKey.isEmpty else {
            throw InsightsError.missingAPIKey
        }
        
        let payloadJSON = try recordingPayloadJSON(payload)
        
        var request = URLRequest(url: Constants.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        let chatRequest = ChatCompletionRequest(
            model: Constants.model,
            messages: [
                .init(role: "system", content: Constants.systemPrompt),
                .init(
                    role: "user",
                    content: """
请根据以下录音转录生成洞察。数据采用 JSON 提供：

<recordings>
\(payloadJSON)
</recordings>
"""
                )
            ],
            temperature: configuration.temperature,
            response_format: .init(type: "json_object")
        )
        
        request.httpBody = try JSONEncoder().encode(chatRequest)
        
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw InsightsError.requestFailed(error.localizedDescription)
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw InsightsError.invalidResponse("无效的 HTTP 响应。")
        }
        
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            if let apiError = try? JSONDecoder().decode(APIErrorResponse.self, from: data) {
                throw InsightsError.requestFailed(apiError.error.message)
            } else {
                let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
                throw InsightsError.requestFailed(message)
            }
        }
        
        let decodedResponse: ChatCompletionResponse
        do {
            decodedResponse = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        } catch {
            throw InsightsError.invalidResponse(error.localizedDescription)
        }
        
        guard let content = decodedResponse.choices.first?.message.content.trimmedNonEmpty else {
            throw InsightsError.emptyMessage
        }
        
        guard let contentData = content.data(using: .utf8) else {
            throw InsightsError.invalidResponse("无法读取 AI JSON 内容。")
        }
        
        do {
            return try JSONDecoder().decode(RecordingInsightsResponse.self, from: contentData)
        } catch {
            throw InsightsError.invalidResponse(error.localizedDescription)
        }
    }
    
    private func recordingPayloadJSON(_ payload: RecordingInsightsPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(payload)
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw InsightsError.invalidResponse("无法生成录音 JSON。")
        }
        return jsonString
    }
}

struct RecordingInsightsPayload: Encodable {
    let recordings: [Entry]
    
    struct Entry: Encodable {
        let id: UUID
        let title: String
        let capturedAt: String
        let capturedAtISO8601: String
        let durationSeconds: Int
        let durationReadable: String
        let transcript: String
        
        init?(recording: Recording) {
            guard let transcript = recording.normalizedTranscriptText else { return nil }
            self.id = recording.id
            self.title = Entry.makeTitle(from: recording)
            self.capturedAt = TimestampFormatter.display(for: recording.timestamp)
            self.capturedAtISO8601 = Entry.isoFormatter.string(from: recording.timestamp)
            self.durationSeconds = Int(recording.duration)
            self.durationReadable = TimeFormatter.display(for: recording.duration)
            self.transcript = transcript
        }
        
        private static func makeTitle(from recording: Recording) -> String {
            if let title = recording.title?.trimmingCharacters(in: .whitespacesAndNewlines),
               !title.isEmpty {
                return title
            }
            return TimestampFormatter.display(for: recording.timestamp)
        }
        
        private static let isoFormatter: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()
    }
}

private extension RecordingInsightsService {
    struct Configuration {
        let temperature: Double
        
        init(environment: [String: String] = ProcessInfo.processInfo.environment) {
            if let raw = environment["OPENAI_INSIGHTS_TEMPERATURE"],
               let value = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
                temperature = value
            } else {
                temperature = 0.35
            }
        }
    }
    
    struct ChatCompletionRequest: Encodable {
        struct ResponseFormat: Encodable {
            let type: String
        }
        
        let model: String
        let messages: [ChatMessage]
        let temperature: Double
        let response_format: ResponseFormat
    }
    
    struct ChatMessage: Encodable {
        let role: String
        let content: String
    }
    
    struct ChatCompletionResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String
            }
            
            let message: Message
        }
        
        let choices: [Choice]
    }
    
    struct APIErrorResponse: Decodable {
        struct APIError: Decodable {
            let message: String
        }
        
        let error: APIError
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

