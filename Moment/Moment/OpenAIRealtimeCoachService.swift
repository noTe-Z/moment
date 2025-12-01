import Foundation

final class OpenAIRealtimeCoachService {
    enum ServiceError: LocalizedError {
        case missingAPIKey
        case notConnected
        case busy
        case remoteError(String)
        case invalidResponse(String)
        
        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "未找到 OpenAI API Key，请在 Xcode Scheme 中配置 OPENAI_API_KEY。"
            case .notConnected:
                return "尚未连接到实时服务，请稍后重试。"
            case .busy:
                return "正在生成上一个提示，请稍后再试。"
            case .remoteError(let message),
                 .invalidResponse(let message):
                return message
            }
        }
    }
    
    enum PromptKind {
        case warmup
        case followUp
    }
    
    private enum ResponsePurpose {
        case prompt
        case summary
    }
    
    var onPromptStreamingUpdate: ((String) -> Void)?
    
    private let contextSnapshot: String
    private let languageDirective: String
    private let apiKey: String
    private var urlSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var pendingContinuation: CheckedContinuation<String, Error>?
    private var pendingPurpose: ResponsePurpose?
    private var sessionUpdateContinuation: CheckedContinuation<Void, Error>?
    private var responseBuffer: String = ""
    private var isListening = false
    
    init(noteContext: String, languageDirective: String) {
        self.contextSnapshot = noteContext
        self.languageDirective = languageDirective
        self.apiKey = OpenAIRewriteService.readAPIKey(for: "OPENAI_API_KEY")
    }
    
    deinit {
        closeConnection()
    }
    
    func connectIfNeeded() async throws {
        guard webSocketTask == nil else { return }
        guard !apiKey.isEmpty else {
            throw ServiceError.missingAPIKey
        }
        
        guard let url = URL(string: "wss://api.openai.com/v1/realtime?model=gpt-realtime-mini-2025-10-06") else {
            throw ServiceError.invalidResponse("无法创建实时服务地址。")
        }
        
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        let session = URLSession(configuration: configuration)
        urlSession = session
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
        
        let task = session.webSocketTask(with: request)
        webSocketTask = task
        task.resume()
        listenForMessages()
        
        try await sendSessionInstruction()
    }
    
    func requestPrompt(kind: PromptKind, sessionHistory: [String], latestUtterance: String?) async throws -> String {
        try await connectIfNeeded()
        
        guard pendingContinuation == nil else {
            throw ServiceError.busy
        }
        
        let instruction = promptInstruction(
            kind: kind,
            history: sessionHistory,
            latestUtterance: latestUtterance
        )
        
        return try await enqueueResponse(instruction: instruction, purpose: .prompt)
    }
    
    func requestSummary(spokenParagraphs: [String]) async throws -> String {
        try await connectIfNeeded()
        
        guard pendingContinuation == nil else {
            throw ServiceError.busy
        }
        
        let instruction = summaryInstruction(spokenParagraphs: spokenParagraphs)
        return try await enqueueResponse(instruction: instruction, purpose: .summary)
    }
    
    func closeConnection() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        if let continuation = sessionUpdateContinuation {
            sessionUpdateContinuation = nil
            continuation.resume(throwing: ServiceError.notConnected)
        }
    }
    
    // MARK: - Private
    
    private func enqueueResponse(instruction: String, purpose: ResponsePurpose) async throws -> String {
        guard let task = webSocketTask else {
            throw ServiceError.notConnected
        }
        
        pendingPurpose = purpose
        responseBuffer = ""
        
        return try await withCheckedThrowingContinuation { [weak self] continuation in
            guard let self else {
                continuation.resume(throwing: ServiceError.notConnected)
                return
            }
            
            self.pendingContinuation = continuation
            
            Task {
                do {
                    let payload: [String: Any] = [
                        "type": "response.create",
                        "response": [
                            "modalities": ["text"],
                            "instructions": instruction
                        ]
                    ]
                    try await self.send(json: payload, using: task)
                } catch {
                    self.pendingContinuation = nil
                    self.pendingPurpose = nil
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    private func sendSessionInstruction() async throws {
        guard let task = webSocketTask else {
            throw ServiceError.notConnected
        }
        
        let instruction = """
        你是一名实时口播教练，会根据用户的练习内容提供一句温暖的引导或追问。
        请严格遵循以下要求：
        1. \(languageDirective)
        2. 优先围绕下方笔记展开，不要引入笔记之外的事实。
        3. 每次仅输出 1-2 句提示，语气友好、鼓励且具体。
        4. 根据练习进度补充未提及的关键点，或者请用户结合自己的真实体验补充细节。
        
        参考笔记：
        <note>
        \(contextSnapshot)
        </note>
        """
        
        let payload: [String: Any] = [
            "type": "session.update",
            "session": [
                "modalities": ["text"],
                "instructions": instruction
            ]
        ]
        
        return try await withCheckedThrowingContinuation { [weak self] continuation in
            guard let self else {
                continuation.resume(throwing: ServiceError.notConnected)
                return
            }
            self.sessionUpdateContinuation = continuation
            
            Task {
                do {
                    try await self.send(json: payload, using: task)
                } catch {
                    self.sessionUpdateContinuation = nil
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    private func send(json: [String: Any], using task: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: json)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ServiceError.invalidResponse("无法序列化实时请求。")
        }
        try await task.send(.string(text))
    }
    
    private func listenForMessages() {
        guard let task = webSocketTask else { return }
        if isListening { return }
        isListening = true
        
        task.receive { [weak self] result in
            guard let self else { return }
            self.isListening = false
            
            switch result {
            case .failure(let error):
                self.handleSocketError(error)
            case .success(let message):
                self.handle(message)
            }
            
            self.listenForMessages()
        }
    }
    
    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .data(let payload):
            data = payload
        case .string(let string):
            data = Data(string.utf8)
        @unknown default:
            return
        }
        
        guard
            let jsonObject = try? JSONSerialization.jsonObject(with: data),
            let json = jsonObject as? [String: Any],
            let type = json["type"] as? String
        else {
            return
        }
        
        switch type {
        case "session.updated":
            if let continuation = sessionUpdateContinuation {
                sessionUpdateContinuation = nil
                continuation.resume(returning: ())
            }
        case "response.output_text.delta", "response.text.delta":
            guard let delta = json["delta"] as? String else { return }
            responseBuffer.append(delta)
            if pendingPurpose == .prompt {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.onPromptStreamingUpdate?(self.responseBuffer.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        case "response.output_text.done", "response.text.done":
            if let finalText = json["text"] as? String {
                responseBuffer = finalText
            }
        case "response.done", "response.completed":
            finishPendingResponse(errorMessage: nil)
        case "error":
            let errorMessage: String
            if let errorDict = json["error"] as? [String: Any],
               let message = errorDict["message"] as? String {
                errorMessage = message
            } else {
                errorMessage = "实时服务返回了未知错误。"
            }
            // Check if it's a session update error
            if let continuation = sessionUpdateContinuation {
                sessionUpdateContinuation = nil
                continuation.resume(throwing: ServiceError.remoteError(errorMessage))
            } else {
                finishPendingResponse(errorMessage: errorMessage)
            }
        default:
            break
        }
    }
    
    private func finishPendingResponse(errorMessage: String?) {
        guard let continuation = pendingContinuation else { return }
        let purpose = pendingPurpose
        pendingContinuation = nil
        pendingPurpose = nil
        
        let text = responseBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        responseBuffer = ""
        
        if let errorMessage {
            continuation.resume(throwing: ServiceError.remoteError(errorMessage))
            return
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if purpose == .prompt {
                self.onPromptStreamingUpdate?(text)
            }
        }
        
        continuation.resume(returning: text)
    }
    
    private func handleSocketError(_ error: Error) {
        if let continuation = sessionUpdateContinuation {
            sessionUpdateContinuation = nil
            continuation.resume(throwing: error)
        }
        if let continuation = pendingContinuation {
            pendingContinuation = nil
            pendingPurpose = nil
            continuation.resume(throwing: error)
        }
    }
    
    private func promptInstruction(kind: PromptKind, history: [String], latestUtterance: String?) -> String {
        let historyText = summarize(Array(history.suffix(4)))
        let latest = latestUtterance?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "（尚未开始口播）"
        
        let modeHint: String
        switch kind {
        case .warmup:
            modeHint = "以欢迎式开场，帮助我进入状态，可以从最核心的主线或第一段开始提问。"
        case .followUp:
            modeHint = "你的问题必须从我刚才的讲述自然衔接到笔记里的下一个重点，或提示我补充真实细节。"
        }
        
        let bridgingDirective = """
        重点：根据「最新一句」的语义，先肯定我刚才的讲述，再指出笔记中最相关或尚未提及的要点，并用一个问题/提示引导我继续复述。
        - 如果我已经覆盖该要点，转向下一个关键点或追问更细节的体验。
        - 每次都引用我刚说的关键词，让衔接听起来自然顺畅。
        """
        
        return """
        \(languageDirective)
        你是一名 AI 口播教练，现在协助我复述已写好的内容。
        最近的口播记录：
        \(historyText)
        
        最新一句：
        \(latest)
        
        \(bridgingDirective)
        \(modeHint)
        请仅输出 1-2 句提示或问题，语气温暖而具体，帮助我继续讲下去。
        """
    }
    
    private func summaryInstruction(spokenParagraphs: [String]) -> String {
        let spokenText = summarize(spokenParagraphs)
        return """
        \(languageDirective)
        你将我在口播练习里说出的内容与原笔记对照，输出一个总结：
        1. 「改写版本」—— 在不丢失信息的前提下，基于口播内容重新表述整段文字。
        2. 「新增角度」—— 用项目符号列出我在口播过程中延伸出的新想法或视角。
        3. 「差异提醒」—— 指出口播内容与原笔记的差异、遗漏或矛盾点，帮助我回到笔记更新。
        
        原笔记：
        <note>
        \(contextSnapshot)
        </note>
        
        口播逐句摘录（按时间顺序）：
        \(spokenText)
        """
    }
    
    private func summarize(_ segments: [String]) -> String {
        guard !segments.isEmpty else {
            return "（暂无内容）"
        }
        return segments.enumerated().map { index, text in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(index + 1). \(trimmed)"
        }.joined(separator: "\n")
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
