import Foundation

struct AssemblyAITranscriptionService {
    private let configuration = Configuration()
    
    enum Stage {
        case uploading
        case transcribing
        case completed
    }
    
    enum TranscriptionError: LocalizedError {
        case missingAPIKey
        case uploadFailed(String)
        case transcriptionFailed(String)
        case invalidResponse(String)
        case pollingTimeout(String)
        case unknown(String)
        
        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "缺少 AssemblyAI API Key。"
            case .uploadFailed(let reason):
                return "上传失败：\(reason)"
            case .transcriptionFailed(let reason):
                return "转写失败：\(reason)"
            case .invalidResponse(let reason):
                return "服务响应异常：\(reason)"
            case .pollingTimeout(let reason):
                return "等待结果超时：\(reason)"
            case .unknown(let reason):
                return "未知错误：\(reason)"
            }
        }
    }
    
    typealias StageHandler = @MainActor (Stage) -> Void
    
    func transcribeAudioFile(at localURL: URL, stageHandler: StageHandler? = nil) async throws -> String {
        let apiKey = Self.readAPIKey(for: "ASSEMBLYAI_API_KEY")
        guard !apiKey.isEmpty else {
            throw TranscriptionError.missingAPIKey
        }
        
        try Task.checkCancellation()
        
        try await notify(.uploading, handler: stageHandler)
        let uploadURL = try await uploadAudio(localURL: localURL, apiKey: apiKey)
        
        try Task.checkCancellation()
        
        try await notify(.transcribing, handler: stageHandler)
        let transcriptID = try await requestTranscript(audioURL: uploadURL, apiKey: apiKey)
        
        try Task.checkCancellation()
        
        let transcript = try await pollTranscript(id: transcriptID, apiKey: apiKey, stageHandler: stageHandler)
        return transcript
    }
}

private extension AssemblyAITranscriptionService {
    enum Constants {
        static let baseURL = URL(string: "https://api.assemblyai.com/v2")!
        static let uploadPathComponent = "upload"
        static let transcriptPathComponent = "transcript"
        static let pollingIntervalNanoseconds: UInt64 = 2_000_000_000
        static let maxPollingAttempts: Int = 45
    }
    
    struct UploadResponse: Decodable {
        let upload_url: String
    }
    
    struct TranscriptCreateResponse: Decodable {
        let id: String
    }
    
    struct TranscriptStatusResponse: Decodable {
        let id: String
        let status: String
        let text: String?
        let error: String?
    }
    
    func uploadAudio(localURL: URL, apiKey: String) async throws -> String {
        let uploadURL = Constants.baseURL.appendingPathComponent(Constants.uploadPathComponent)
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        
        let fileData: Data
        do {
            fileData = try Data(contentsOf: localURL)
        } catch {
            throw TranscriptionError.uploadFailed("无法读取录音文件：\(error.localizedDescription)")
        }
        
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.upload(for: request, from: fileData)
        } catch {
            throw TranscriptionError.uploadFailed(error.localizedDescription)
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse("无效的上传响应。")
        }
        
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw TranscriptionError.uploadFailed(message)
        }
        
        do {
            let decoded = try JSONDecoder().decode(UploadResponse.self, from: data)
            return decoded.upload_url
        } catch {
            throw TranscriptionError.invalidResponse("解析上传响应失败：\(error.localizedDescription)")
        }
    }
    
    func requestTranscript(audioURL: String, apiKey: String) async throws -> String {
        let transcriptURL = Constants.baseURL.appendingPathComponent(Constants.transcriptPathComponent)
        var request = URLRequest(url: transcriptURL)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        var payload: [String: Any] = [
            "audio_url": audioURL,
            "format_text": true,
            "punctuate": configuration.enablePunctuation,
            "language_detection": configuration.shouldDetectLanguage
        ]
        
        if let languageCode = configuration.languageCode {
            payload["language_code"] = languageCode
        }
        
        if let speechModel = configuration.speechModel {
            payload["model"] = speechModel
        }
        
        if !configuration.wordBoost.isEmpty {
            payload["word_boost"] = configuration.wordBoost
            payload["boost_param"] = configuration.wordBoostStrength
        }
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            throw TranscriptionError.invalidResponse("构建转写请求失败：\(error.localizedDescription)")
        }
        
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw TranscriptionError.transcriptionFailed("创建转写任务失败：\(error.localizedDescription)")
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse("无效的转写响应。")
        }
        
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw TranscriptionError.transcriptionFailed(message)
        }
        
        do {
            let decoded = try JSONDecoder().decode(TranscriptCreateResponse.self, from: data)
            return decoded.id
        } catch {
            throw TranscriptionError.invalidResponse("解析转写任务响应失败：\(error.localizedDescription)")
        }
    }
    
    func pollTranscript(id: String, apiKey: String, stageHandler: StageHandler?) async throws -> String {
        let pollURL = Constants.baseURL
            .appendingPathComponent(Constants.transcriptPathComponent)
            .appendingPathComponent(id)
        
        var attempts = 0
        
        while attempts < Constants.maxPollingAttempts {
            try Task.checkCancellation()
            
            var request = URLRequest(url: pollURL)
            request.httpMethod = "GET"
            request.setValue(apiKey, forHTTPHeaderField: "Authorization")
            
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                throw TranscriptionError.transcriptionFailed("查询转写状态失败：\(error.localizedDescription)")
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw TranscriptionError.invalidResponse("无效的轮询响应。")
            }
            
            guard (200 ..< 300).contains(httpResponse.statusCode) else {
                let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
                throw TranscriptionError.transcriptionFailed(message)
            }
            
            let statusResponse: TranscriptStatusResponse
            do {
                statusResponse = try JSONDecoder().decode(TranscriptStatusResponse.self, from: data)
            } catch {
                throw TranscriptionError.invalidResponse("解析轮询响应失败：\(error.localizedDescription)")
            }
            
            switch statusResponse.status.lowercased() {
            case "queued", "processing":
                attempts += 1
                try await Task.sleep(nanoseconds: Constants.pollingIntervalNanoseconds)
                continue
            case "completed":
                try await notify(.completed, handler: stageHandler)
                if let text = statusResponse.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text
                } else {
                    throw TranscriptionError.transcriptionFailed("转写成功但返回文本为空。")
                }
            case "error":
                let message = statusResponse.error ?? "服务返回错误。"
                throw TranscriptionError.transcriptionFailed(message)
            default:
                let message = "未知状态：\(statusResponse.status)"
                throw TranscriptionError.invalidResponse(message)
            }
        }
        
        throw TranscriptionError.pollingTimeout("在预设时间内未完成转写。")
    }
    
    func notify(_ stage: Stage, handler: StageHandler?) async throws {
        guard let handler else { return }
        try Task.checkCancellation()
        await MainActor.run {
            handler(stage)
        }
    }
}

private extension AssemblyAITranscriptionService {
    struct Configuration {
        let languageCode: String?
        let speechModel: String?
        let enablePunctuation: Bool
        let wordBoost: [String]
        let wordBoostStrength: String
        
        init(environment: [String: String] = ProcessInfo.processInfo.environment) {
            languageCode = environment["ASSEMBLYAI_LANGUAGE_CODE"].flatMap { $0.trimmedNonEmpty }
            speechModel = environment["ASSEMBLYAI_SPEECH_MODEL"].flatMap { $0.trimmedNonEmpty }
            
            if let punctuationRaw = environment["ASSEMBLYAI_PUNCTUATE"], !punctuationRaw.isEmpty {
                enablePunctuation = Bool(fromEnvironment: punctuationRaw)
            } else {
                enablePunctuation = true
            }
            
            if let boostRaw = environment["ASSEMBLYAI_WORD_BOOST"], !boostRaw.isEmpty {
                wordBoost = boostRaw
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            } else {
                wordBoost = []
            }
            
            if let boostStrengthRaw = environment["ASSEMBLYAI_WORD_BOOST_STRENGTH"]?.lowercased(),
               ["low", "medium", "high"].contains(boostStrengthRaw) {
                wordBoostStrength = boostStrengthRaw
            } else {
                wordBoostStrength = "high"
            }
        }
        
        var shouldDetectLanguage: Bool {
            languageCode == nil
        }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension Bool {
    init(fromEnvironment rawValue: String) {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self = ["1", "true", "yes", "y", "on"].contains(normalized)
    }
}

extension AssemblyAITranscriptionService {
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


