import Foundation
import SwiftUI
import UIKit

@MainActor
final class NarrationCoachViewModel: ObservableObject {
    struct TranscriptEntry: Identifiable {
        let id = UUID()
        let text: String
        let timestamp: Date
    }
    
    struct PromptEntry: Identifiable {
        let id = UUID()
        let text: String
        let timestamp: Date
    }
    
    enum SessionState: Equatable {
        case idle
        case connecting
        case awaitingPrompt
        case listening
        case summarizing
        case completed
        case failed(String)
    }
    
    @Published private(set) var state: SessionState = .idle
    @Published private(set) var currentPrompt: String = "点击开始，AI 会根据笔记内容给出第一句提示。"
    @Published private(set) var transcriptEntries: [TranscriptEntry] = []
    @Published private(set) var transcriptPreview: String = ""
    @Published private(set) var promptHistory: [PromptEntry] = []
    @Published private(set) var summaryText: String?
    @Published private(set) var isRecording: Bool = false
    @Published var showErrorAlert = false
    @Published private(set) var isCopyToastVisible = false
    @Published private(set) var errorMessage: String?
    
    var onSummaryGenerated: ((String) -> Void)?
    
    private let languageHint: LanguageHint
    private let service: OpenAIRealtimeCoachService
    private let speechRecognizer: LiveSpeechRecognizer
    
    init(noteTitle: String, noteContent: String, onSummaryGenerated: ((String) -> Void)? = nil) {
        let snapshot = Self.composeSnapshot(title: noteTitle, content: noteContent)
        self.languageHint = LanguageHint(text: snapshot)
        self.service = OpenAIRealtimeCoachService(
            noteContext: snapshot,
            languageDirective: languageHint.directive
        )
        self.speechRecognizer = LiveSpeechRecognizer(localeIdentifier: languageHint.localeIdentifier)
        self.onSummaryGenerated = onSummaryGenerated
        
        speechRecognizer.onTranscription = { [weak self] text, isFinal in
            guard let self else { return }
            Task { @MainActor in
                self.handleTranscription(text: text, isFinal: isFinal)
            }
        }
        
        speechRecognizer.onError = { [weak self] error in
            Task { @MainActor in
                self?.handleError(error)
            }
        }
        
        service.onPromptStreamingUpdate = { [weak self] streamed in
            Task { @MainActor in
                self?.currentPrompt = streamed
            }
        }
    }
    
    func toggleSession() {
        switch state {
        case .idle, .completed, .failed(_):
            startSession()
        case .connecting, .awaitingPrompt, .listening:
            stopSession()
        case .summarizing:
            break
        }
    }
    
    func startSession() {
        guard !isRecording else { return }
        state = .connecting
        currentPrompt = "正在准备提示…"
        
        Task {
            do {
                try await service.connectIfNeeded()
                try await speechRecognizer.start()
                isRecording = true
                try await fetchWarmupPrompt()
            } catch {
                handleError(error)
            }
        }
    }
    
    func stopSession() {
        guard isRecording else { return }
        isRecording = false
        speechRecognizer.stop()
        state = .summarizing
        currentPrompt = "正在整理本次练习…"
        
        Task {
            do {
                let spoken = transcriptEntries.map(\.text)
                let summary = try await service.requestSummary(spokenParagraphs: spoken)
                summaryText = summary
                onSummaryGenerated?(summary)
                state = .completed
            } catch {
                handleError(error)
            }
        }
    }
    
    func tearDown() {
        speechRecognizer.stop()
        service.closeConnection()
    }
    
    func copySummaryToPasteboard() {
        guard let summaryText else { return }
        UIPasteboard.general.string = summaryText
        isCopyToastVisible = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            self?.isCopyToastVisible = false
        }
    }
    
    var statusText: String {
        switch state {
        case .idle:
            return "准备开始"
        case .connecting:
            return "连接中…"
        case .awaitingPrompt:
            return "生成提示…"
        case .listening:
            return "聆听中"
        case .summarizing:
            return "生成总结…"
        case .completed:
            return "练习完成"
        case .failed(_):
            return "出现错误"
        }
    }
    
    private func fetchWarmupPrompt() async throws {
        state = .awaitingPrompt
        let prompt = try await service.requestPrompt(
            kind: .warmup,
            sessionHistory: transcriptEntries.map(\.text),
            latestUtterance: nil
        )
        promptHistory.append(PromptEntry(text: prompt, timestamp: Date()))
        currentPrompt = prompt
        state = .listening
    }
    
    private func handleTranscription(text: String, isFinal: Bool) {
        guard isRecording else { return }
        transcriptPreview = text
        
        if isFinal {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            transcriptPreview = ""
            guard !trimmed.isEmpty else { return }
            transcriptEntries.append(TranscriptEntry(text: trimmed, timestamp: Date()))
            Task {
                await self.fetchFollowUpPrompt(for: trimmed)
            }
        }
    }
    
    private func fetchFollowUpPrompt(for latest: String) async {
        guard isRecording else { return }
        state = .awaitingPrompt
        do {
            let prompt = try await service.requestPrompt(
                kind: .followUp,
                sessionHistory: transcriptEntries.map(\.text),
                latestUtterance: latest
            )
            promptHistory.append(PromptEntry(text: prompt, timestamp: Date()))
            currentPrompt = prompt
            state = .listening
        } catch {
            handleError(error)
        }
    }
    
    private func handleError(_ error: Error) {
        speechRecognizer.stop()
        isRecording = false
        state = .failed(error.localizedDescription)
        errorMessage = error.localizedDescription
        showErrorAlert = true
    }
}

private extension NarrationCoachViewModel {
    static func composeSnapshot(title: String, content: String) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (trimmedTitle.isEmpty, trimmedContent.isEmpty) {
        case (false, false):
            return "# \(trimmedTitle)\n\n\(trimmedContent)"
        case (false, true):
            return trimmedTitle
        case (true, false):
            return trimmedContent
        default:
            return "（空白笔记）"
        }
    }
    
    struct LanguageHint {
        let localeIdentifier: String
        let directive: String
        
        init(text: String) {
            if text.containsChineseCharacters {
                localeIdentifier = "zh-CN"
                directive = "请全程使用自然的简体中文回复。"
            } else {
                let preferred = Locale.preferredLanguages.first ?? "en-US"
                let locale = Locale(identifier: preferred)
                localeIdentifier = preferred
                let languageIdentifier: String
                if #available(iOS 16, *) {
                    languageIdentifier = locale.language.languageCode?.identifier ?? "en"
                } else {
                    languageIdentifier = locale.languageCode ?? "en"
                }
                let displayName = Locale.current.localizedString(forLanguageCode: languageIdentifier) ?? "English"
                directive = "Please respond in \(displayName) and keep the tone encouraging."
            }
        }
    }
}

private extension String {
    var containsChineseCharacters: Bool {
        range(of: #"\p{Han}"#, options: .regularExpression) != nil
    }
}


