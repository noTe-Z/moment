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
                return "未找到 OpenAI API Key，请在 Xcode Scheme 中设置 OPENAI_API_KEY。"
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
        static let model = "gpt-5-mini"
    }
    
    func rewrite(text: String) async throws -> String {
        let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
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
                .init(role: "system", content: "你是一位中文写作助手，擅长将零散笔记整理成流畅、有逻辑、易于理解的段落。请保持内容忠实于原始含义，并突出重点。"),
                .init(role: "user", content: "请将以下文本整理成一段结构清晰、语义连贯的中文段落，保留核心信息并避免无关赘述：\n\n\(text)")
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

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

