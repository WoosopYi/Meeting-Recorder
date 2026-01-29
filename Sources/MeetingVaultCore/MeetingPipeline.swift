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

        let promptTranscript = Self.formatTranscriptForPrompt(transcript)
        let prompt = MeetingNotesPrompts.summarizePrompt(transcript: promptTranscript)
        let raw = try await GeminiClient(apiKey: geminiKey, model: geminiModel).generateText(prompt: prompt)

        guard let jsonString = JSONExtractor.extractFirstJSONObject(from: raw) else {
            throw MeetingPipelineError.geminiReturnedNoJSON
        }
        let notes = try JSONDecoder().decode(MeetingNotes.self, from: Data(jsonString.utf8))

        // Persist notes JSON.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let notesData = try encoder.encode(notes)
        try notesData.write(to: session.notesJSON, options: [.atomic])

        let markdown = MeetingNotesMarkdown.render(meetingId: session.meetingId, notes: notes)
        try markdown.write(to: session.notesMarkdown, atomically: true, encoding: .utf8)

        return MeetingPipelineResult(transcript: transcript, notes: notes)
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

    private static func formatTranscriptForPrompt(_ transcript: Transcript) -> String {
        transcript.segments
            .enumerated()
            .map { index, segment in
                let start = formatTimestampMs(segment.startMs)
                let end = formatTimestampMs(segment.endMs)
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return "[\(start)-\(end)] \(text)"
            }
            .joined(separator: "\n")
    }

    private static func formatTimestampMs(_ ms: Int) -> String {
        let clamped = max(0, ms)
        let totalSeconds = clamped / 1000
        let milliseconds = clamped % 1000

        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, milliseconds)
    }
}
