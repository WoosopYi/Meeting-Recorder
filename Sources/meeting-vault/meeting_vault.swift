import Foundation
import MeetingVaultCore

@main
struct MeetingVaultCLI {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard let command = args.first else {
                Self.printUsage()
                return
            }

            switch command {
            case "record":
                let options = try RecordOptions.parse(Array(args.dropFirst()))
                try await Self.runRecord(options)
            case "transcribe":
                let options = try TranscribeOptions.parse(Array(args.dropFirst()))
                try Self.runTranscribe(options)
            case "summarize":
                let options = try SummarizeOptions.parse(Array(args.dropFirst()))
                try await Self.runSummarize(options)
            case "export-notion":
                let options = try ExportNotionOptions.parse(Array(args.dropFirst()))
                try await Self.runExportNotion(options)
            default:
                Self.printUsage()
            }
        } catch {
            fputs("error: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func printUsage() {
        print(
            """
            meeting-vault

            Usage:
              meeting-vault record [--segment-seconds N] [--duration-seconds N]
                                 [--output PATH]

              meeting-vault transcribe --audio PATH [--model PATH] [--bin NAME_OR_PATH]
                                      [--language CODE]
                                      [--text-out PATH] [--segments-out PATH]

              meeting-vault summarize --transcript PATH [--out PATH]

              meeting-vault export-notion --notes PATH [--title TEXT]

            Notes:
              - This is an early dev CLI to validate mic-only recording.
              - On macOS, microphone permission is managed by TCC.
            """
        )
    }

    private static func runRecord(_ options: RecordOptions) async throws {
        let granted = await MicrophonePermission.requestIfNeeded()
        guard granted else {
            throw CLIError.microphonePermissionDenied
        }

        let session = try RecordingSession.create(baseOutput: options.outputPath)
        print("Session: \(session.meetingId)")
        print("Output:  \(session.root.path)")
        print("Press Ctrl+C to stop.")

        let eventLogger = try EventLogger(logURL: session.eventLog)
        await eventLogger.log(EventLogger.info("recording_session_created", [
            "meeting_id": session.meetingId,
            "root": session.root.path,
        ]))

        let notifier = LocalNotifier()

        let sleepInhibitor = SleepInhibitor(reason: "MeetingVault recording")
        sleepInhibitor.start()

        let recorder = ChunkedMicRecorder(
            outputDirectory: session.audioChunks,
            fullFileURL: session.audioFull,
            segmentSeconds: options.segmentSeconds
        )

        recorder.onEvent = { event in
            Task { await eventLogger.log(event) }
        }
        recorder.onIssue = { issue in
            Task {
                await eventLogger.log(EventLogger.warn(issue.kind.rawValue, [
                    "message": issue.message
                ]))
                await notifier.notify(
                    title: "MeetingVault recording issue",
                    body: issue.message
                )
            }
        }

        try recorder.start()

        // Handle Ctrl+C.
        signal(SIGINT, SIG_IGN)
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigintSource.setEventHandler {
            recorder.stop()
            sleepInhibitor.stop()
            exit(0)
        }
        sigintSource.resume()

        if let durationSeconds = options.durationSeconds {
            try await Task.sleep(nanoseconds: UInt64(durationSeconds) * 1_000_000_000)
            recorder.stop()
            sleepInhibitor.stop()
            return
        }

        dispatchMain()
    }

    private static func runTranscribe(_ options: TranscribeOptions) throws {
        let modelPath = options.modelPath
            ?? ProcessInfo.processInfo.environment["MEETINGVAULT_WHISPER_MODEL"]

        guard let modelPath, !modelPath.isEmpty else {
            throw CLIError.invalidArguments("Missing --model (or set MEETINGVAULT_WHISPER_MODEL)")
        }

        let bin = options.binary
            ?? ProcessInfo.processInfo.environment["MEETINGVAULT_WHISPER_BIN"]
            ?? "whisper-cli"

        let transcriber = WhisperCppTranscriber(
            binary: bin,
            modelPath: modelPath,
            language: options.language
        )

        let transcript = try transcriber.transcribe(audioPath: options.audioPath)

        if let textOut = options.textOut {
            try transcript.text.write(to: textOut, atomically: true, encoding: .utf8)
        }
        if let segmentsOut = options.segmentsOut {
            let encoder = JSONEncoder()
            FileManager.default.createFile(atPath: segmentsOut.path, contents: nil)
            let handle = try FileHandle(forWritingTo: segmentsOut)
            defer { try? handle.close() }
            for segment in transcript.segments {
                let data = try encoder.encode(segment)
                handle.write(data)
                handle.write(Data("\n".utf8))
            }
            try handle.synchronize()
        }

        if options.textOut == nil && options.segmentsOut == nil {
            print(transcript.text)
        }
    }

    private static func runSummarize(_ options: SummarizeOptions) async throws {
        let apiKey =
            ProcessInfo.processInfo.environment["MEETINGVAULT_GEMINI_API_KEY"]
            ?? ProcessInfo.processInfo.environment["GEMINI_API_KEY"]
            ?? ""
        let model =
            ProcessInfo.processInfo.environment["MEETINGVAULT_GEMINI_MODEL"]
            ?? "gemini-3-flash-preview"

        let transcriptText = try String(contentsOf: options.transcriptPath, encoding: .utf8)

        let prompt = MeetingNotesPrompts.summarizePrompt(transcript: transcriptText)
        let client = GeminiClient(apiKey: apiKey, model: model)
        let raw = try await client.generateText(prompt: prompt)

        guard let jsonString = Self.extractFirstJSON(from: raw) else {
            throw CLIError.invalidArguments("Gemini did not return JSON")
        }

        let decoder = JSONDecoder()
        let data = Data(jsonString.utf8)
        let notes = try decoder.decode(MeetingNotes.self, from: data)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let pretty = try encoder.encode(notes)
        let output = String(data: pretty, encoding: .utf8) ?? jsonString

        if let out = options.outPath {
            try output.write(to: out, atomically: true, encoding: .utf8)
        } else {
            print(output)
        }
    }

    private static func runExportNotion(_ options: ExportNotionOptions) async throws {
        let token =
            ProcessInfo.processInfo.environment["MEETINGVAULT_NOTION_TOKEN"]
            ?? ProcessInfo.processInfo.environment["NOTION_TOKEN"]
            ?? ""
        let databaseId =
            ProcessInfo.processInfo.environment["MEETINGVAULT_NOTION_DATABASE_ID"]
            ?? ProcessInfo.processInfo.environment["NOTION_DATABASE_ID"]
            ?? ""

        guard !databaseId.isEmpty else {
            throw CLIError.invalidArguments("Missing MEETINGVAULT_NOTION_DATABASE_ID")
        }

        let notesData = try Data(contentsOf: options.notesPath)
        let decoder = JSONDecoder()
        let notes = try decoder.decode(MeetingNotes.self, from: notesData)

        let title = options.titleOverride
            ?? notes.title
            ?? "Meeting Notes"

        let client = NotionClient(token: token)
        let pageId = try await client.createMeetingPage(databaseId: databaseId, title: title, notes: notes)
        print(pageId)
    }

    private static func extractFirstJSON(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        guard let end = text.lastIndex(of: "}") else { return nil }
        guard start < end else { return nil }
        return String(text[start...end])
    }
}

struct RecordOptions {
    var segmentSeconds: TimeInterval = 30
    var durationSeconds: UInt64?
    var outputPath: String?

    static func parse(_ args: [String]) throws -> RecordOptions {
        var options = RecordOptions()
        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--segment-seconds":
                i += 1
                guard i < args.count, let v = Double(args[i]), v > 0 else {
                    throw CLIError.invalidArguments("--segment-seconds requires a positive number")
                }
                options.segmentSeconds = v
            case "--duration-seconds":
                i += 1
                guard i < args.count, let v = UInt64(args[i]), v > 0 else {
                    throw CLIError.invalidArguments("--duration-seconds requires a positive integer")
                }
                options.durationSeconds = v
            case "--output":
                i += 1
                guard i < args.count else {
                    throw CLIError.invalidArguments("--output requires a path")
                }
                options.outputPath = args[i]
            default:
                throw CLIError.invalidArguments("Unknown argument: \(arg)")
            }
            i += 1
        }
        return options
    }
}

struct TranscribeOptions {
    var audioPath: URL
    var modelPath: String?
    var binary: String?
    var language: String?
    var textOut: URL?
    var segmentsOut: URL?

    static func parse(_ args: [String]) throws -> TranscribeOptions {
        var audio: URL?
        var model: String?
        var binary: String?
        var language: String?
        var textOut: URL?
        var segmentsOut: URL?

        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--audio":
                i += 1
                guard i < args.count else { throw CLIError.invalidArguments("--audio requires a path") }
                audio = URL(fileURLWithPath: args[i])
            case "--model":
                i += 1
                guard i < args.count else { throw CLIError.invalidArguments("--model requires a path") }
                model = args[i]
            case "--bin":
                i += 1
                guard i < args.count else { throw CLIError.invalidArguments("--bin requires a name/path") }
                binary = args[i]
            case "--language":
                i += 1
                guard i < args.count else { throw CLIError.invalidArguments("--language requires a code") }
                language = args[i]
            case "--text-out":
                i += 1
                guard i < args.count else { throw CLIError.invalidArguments("--text-out requires a path") }
                textOut = URL(fileURLWithPath: args[i])
            case "--segments-out":
                i += 1
                guard i < args.count else { throw CLIError.invalidArguments("--segments-out requires a path") }
                segmentsOut = URL(fileURLWithPath: args[i])
            default:
                throw CLIError.invalidArguments("Unknown argument: \(arg)")
            }
            i += 1
        }

        guard let audio else {
            throw CLIError.invalidArguments("Missing --audio")
        }

        return TranscribeOptions(
            audioPath: audio,
            modelPath: model,
            binary: binary,
            language: language,
            textOut: textOut,
            segmentsOut: segmentsOut
        )
    }
}

struct SummarizeOptions {
    var transcriptPath: URL
    var outPath: URL?

    static func parse(_ args: [String]) throws -> SummarizeOptions {
        var transcript: URL?
        var out: URL?

        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--transcript":
                i += 1
                guard i < args.count else { throw CLIError.invalidArguments("--transcript requires a path") }
                transcript = URL(fileURLWithPath: args[i])
            case "--out":
                i += 1
                guard i < args.count else { throw CLIError.invalidArguments("--out requires a path") }
                out = URL(fileURLWithPath: args[i])
            default:
                throw CLIError.invalidArguments("Unknown argument: \(arg)")
            }
            i += 1
        }

        guard let transcript else {
            throw CLIError.invalidArguments("Missing --transcript")
        }

        return SummarizeOptions(transcriptPath: transcript, outPath: out)
    }
}

struct ExportNotionOptions {
    var notesPath: URL
    var titleOverride: String?

    static func parse(_ args: [String]) throws -> ExportNotionOptions {
        var notes: URL?
        var title: String?

        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--notes":
                i += 1
                guard i < args.count else { throw CLIError.invalidArguments("--notes requires a path") }
                notes = URL(fileURLWithPath: args[i])
            case "--title":
                i += 1
                guard i < args.count else { throw CLIError.invalidArguments("--title requires text") }
                title = args[i]
            default:
                throw CLIError.invalidArguments("Unknown argument: \(arg)")
            }
            i += 1
        }

        guard let notes else {
            throw CLIError.invalidArguments("Missing --notes")
        }

        return ExportNotionOptions(notesPath: notes, titleOverride: title)
    }
}

enum CLIError: LocalizedError {
    case invalidArguments(String)
    case microphonePermissionDenied

    var errorDescription: String? {
        switch self {
        case let .invalidArguments(message):
            return message
        case .microphonePermissionDenied:
            return "Microphone permission denied"
        }
    }
}

final class LocalNotifier {
    func notify(title: String, body: String) async {
        // Best-effort notification when running as a SwiftPM executable.
        // Avoids UNUserNotificationCenter, which expects a proper .app bundle.
        let safeTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        let safeBody = body
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")

        let script = "display notification \"\(safeBody)\" with title \"\(safeTitle)\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()

        fputs("[notification] \(title): \(body)\n", stderr)
    }
}
