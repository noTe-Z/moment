import Foundation

struct OpenAIRewriteService {
    private let configuration = Configuration()
    
    enum RewriteError: LocalizedError {
        case missingAPIKey
        case requestFailed(String)
        case invalidResponse(String)
        case emptyResult
        
        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "未找到 OpenAI API Key，请在 Xcode Build Settings 或 Scheme 中设置 OPENAI_API_KEY。"
            case .requestFailed(let message):
                return "请求失败：\(message)"
            case .invalidResponse(let message):
                return "响应解析失败：\(message)"
            case .emptyResult:
                return "AI 返回的内容为空，请稍后重试。"
            }
        }
    }
    
    private enum Constants {
        static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
        static let model = "gpt-4o-mini"
    }
    
    func rewrite(text: String) async throws -> String {
        let apiKey = Self.readAPIKey(for: "OPENAI_API_KEY")
        guard !apiKey.isEmpty else {
            throw RewriteError.missingAPIKey
        }
        
        var request = URLRequest(url: Constants.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        let payload = ChatCompletionRequest(
            model: Constants.model,
            messages: [
                .init(
                    role: "system",
                    content: """
You are a living-note curator who iteratively polishes a document without losing information.

Your responsibilities:
1. Treat everything between <note> tags as the canonical source. Preserve every idea and section unless the writer explicitly marks it for deletion (e.g., "DELETE:" or "[x]").
2. Detect the document shape. If it is a single storyline, return one refined paragraph. If it contains multiple themes or labeled sections, output a "Main Summary" first and then the sections (reuse the existing names/order when possible, or create clearer ones such as "Highlights", "Decisions", "Open Questions", "Limitations", "Next Actions", "Side Notes").
3. Within each section, rewrite every bullet/paragraph for clarity while keeping intent. Integrate any new sentences into the most relevant section(s); you may merge duplicates, but never drop prior points.
4. Maintain the original language mix, add no new data, and output only the rewritten note.
5. If the first non-empty line is a Markdown heading such as "# 核心主线" or "# Main Thread", treat that section as the canonical storyline: keep the heading title as-is, polish the text gently, and ensure it stays before any other section.
6. Reuse existing Markdown headings (including bullets like "Limitations", "Open Questions", etc.) as anchors. Only introduce new headings when new ideas cannot live inside existing ones, and clearly label any new sections.
"""
                ),
                .init(
                    role: "user",
                    content: """
Process the note below by following the curation rules: map the existing structure, decide whether it should be a single paragraph or a structured layout, then integrate every idea into that structure (keep "# 核心主线" at the very top if it exists). Always reply in the same language as the note.

<note>
\(text)
</note>
"""
                )
            ],
            temperature: configuration.temperature
        )
        
        do {
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            throw RewriteError.invalidResponse("无法编码请求体：\(error.localizedDescription)")
        }
        
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw RewriteError.requestFailed(error.localizedDescription)
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RewriteError.invalidResponse("无效的 HTTP 响应。")
        }
        
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            if let apiError = try? JSONDecoder().decode(APIErrorResponse.self, from: data) {
                throw RewriteError.requestFailed(apiError.error.message)
            } else {
                let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
                throw RewriteError.requestFailed(message)
            }
        }
        
        let decodedResponse: ChatCompletionResponse
        do {
            decodedResponse = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        } catch {
            throw RewriteError.invalidResponse(error.localizedDescription)
        }
        
        guard let content = decodedResponse.choices.first?.message.content.trimmedNonEmpty else {
            throw RewriteError.emptyResult
        }
        
        return content
    }
}

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double?
}

private struct ChatMessage: Encodable {
    let role: String
    let content: String
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String
        }
        
        let message: Message
    }
    
    let choices: [Choice]
}

private struct APIErrorResponse: Decodable {
    struct APIError: Decodable {
        let message: String
    }
    
    let error: APIError
}

private extension OpenAIRewriteService {
    struct Configuration {
        let temperature: Double?
        
        init(environment: [String: String] = ProcessInfo.processInfo.environment) {
            if let rawTemperature = environment["OPENAI_REWRITE_TEMPERATURE"],
               let value = Double(rawTemperature.trimmingCharacters(in: .whitespacesAndNewlines)) {
                temperature = value
            } else {
                temperature = nil
            }
        }
    }
}

extension OpenAIRewriteService {
    /// 读取 API key，优先从环境变量读取，如果没有则从 Info.plist (Build Settings) 读取
    static func readAPIKey(for key: String) -> String {
        if let sanitizedEnv = sanitizedValue(ProcessInfo.processInfo.environment[key]) {
            return sanitizedEnv
        }
        if let rawBundleValue = Bundle.main.object(forInfoDictionaryKey: key) as? String,
           let sanitizedBundle = sanitizedValue(rawBundleValue) {
            return sanitizedBundle
        }
        return ""
    }
    
    private static func sanitizedValue(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        var trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        trimmed = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !trimmed.isEmpty else { return nil }
        
        let lowercase = trimmed.lowercased()
        let isPlaceholder =
            trimmed.contains("$(") ||
            trimmed.contains("__PLACEHOLDER__") ||
            trimmed.contains("<#") ||
            lowercase.contains("your_")
        
        return isPlaceholder ? nil : trimmed
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

