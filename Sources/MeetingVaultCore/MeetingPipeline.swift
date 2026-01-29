import Foundation

public enum MeetingPipelineError: LocalizedError {
    case missingConfig(String)
    case geminiReturnedNoJSON

    public var errorDescription: String? {
        switch self {
        case let .missingConfig(message):
            return message
        case .geminiReturnedNoJSON:
            return "Gemini did not return JSON"
        }
    }
}

public struct MeetingPipelineResult: Sendable {
    public let transcript: Transcript
    public let notes: MeetingNotes
    public let notionPageId: String
}

public enum MeetingPipeline {
    public static func process(session: RecordingSession, config: AppConfig) async throws -> MeetingPipelineResult {
        let whisperModelPath = config.whisperModelPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !whisperModelPath.isEmpty else {
            throw MeetingPipelineError.missingConfig("Missing config.whisperModelPath (install whisper-cpp and set a ggml model path)")
        }
        let whisperBin = (config.whisperBinary?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "whisper-cli"

        let transcript = try await runBlocking {
            let transcriber = WhisperCppTranscriber(
                binary: whisperBin,
                modelPath: whisperModelPath,
                language: config.whisperLanguage
            )
            return try transcriber.transcribe(audioPath: session.audioFull)
        }

        // Persist transcript artifacts.
        try WhisperCppTranscriber.writeTranscript(
            transcript,
            textURL: session.transcriptText,
            segmentsJSONLURL: session.transcriptSegments
        )

        let geminiKey = config.geminiApiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !geminiKey.isEmpty else {
            throw MeetingPipelineError.missingConfig("Missing config.geminiApiKey")
        }
        let geminiModel = (config.geminiModel?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "gemini-3-flash-preview"

        let prompt = MeetingNotesPrompts.summarizePrompt(transcript: transcript.text)
        let raw = try await GeminiClient(apiKey: geminiKey, model: geminiModel).generateText(prompt: prompt)

        guard let jsonString = extractFirstJSON(from: raw) else {
            throw MeetingPipelineError.geminiReturnedNoJSON
        }
        let notes = try JSONDecoder().decode(MeetingNotes.self, from: Data(jsonString.utf8))

        // Persist notes JSON.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let notesData = try encoder.encode(notes)
        try notesData.write(to: session.notesJSON, options: [.atomic])

        let notionToken = config.notionToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let notionDb = config.notionDatabaseId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !notionToken.isEmpty else {
            throw MeetingPipelineError.missingConfig("Missing config.notionToken")
        }
        guard !notionDb.isEmpty else {
            throw MeetingPipelineError.missingConfig("Missing config.notionDatabaseId")
        }

        let title = notes.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let pageTitle = (title?.isEmpty == false) ? title! : "Meeting Notes"

        let notion = NotionClient(token: notionToken)
        let pageId = try await notion.createMeetingPage(databaseId: notionDb, title: pageTitle, notes: notes)

        return MeetingPipelineResult(transcript: transcript, notes: notes, notionPageId: pageId)
    }

    private static func runBlocking<T>(_ work: @Sendable @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func extractFirstJSON(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        guard let end = text.lastIndex(of: "}") else { return nil }
        guard start < end else { return nil }
        return String(text[start...end])
    }
}
