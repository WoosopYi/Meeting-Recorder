import Foundation

public struct TranscriptSegment: Codable, Sendable {
    public let startMs: Int
    public let endMs: Int
    public let text: String

    public init(startMs: Int, endMs: Int, text: String) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
    }
}

public struct Transcript: Codable, Sendable {
    public let segments: [TranscriptSegment]

    public init(segments: [TranscriptSegment]) {
        self.segments = segments
    }

    public var text: String {
        segments
            .map { $0.text }
            .joined(separator: "\n")
    }
}

public enum WhisperCppError: LocalizedError {
    case missingBinary(String)
    case missingModel(String)
    case processFailed(exitCode: Int32, stderr: String)
    case outputDecodingFailed

    public var errorDescription: String? {
        switch self {
        case let .missingBinary(pathOrName):
            return "whisper-cli not found: \(pathOrName)"
        case let .missingModel(path):
            return "Whisper model file not found: \(path)"
        case let .processFailed(exitCode, stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "whisper-cli failed (exit \(exitCode)): \(trimmed)"
        case .outputDecodingFailed:
            return "Failed to decode whisper-cli output"
        }
    }
}

public final class WhisperCppTranscriber {
    public let binary: String
    public let modelPath: String

    /// Optional language hint (ISO code like "ko").
    public let language: String?

    public init(binary: String = "whisper-cli", modelPath: String, language: String? = nil) {
        self.binary = binary
        self.modelPath = modelPath
        self.language = language
    }

    public func transcribe(audioPath: URL) throws -> Transcript {
        let fm = FileManager.default
        guard fm.fileExists(atPath: modelPath) else {
            throw WhisperCppError.missingModel(modelPath)
        }

        // Use /usr/bin/env so `binary` can be just "whisper-cli".
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")

        var args: [String] = [binary, "-m", modelPath, "-f", audioPath.path]
        if let language, !language.isEmpty {
            // whisper.cpp commonly uses -l for language; keep this optional and best-effort.
            args.append(contentsOf: ["-l", language])
        }
        process.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw WhisperCppError.missingBinary(binary)
        }

        process.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

        let stderr = String(data: errData, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw WhisperCppError.processFailed(exitCode: process.terminationStatus, stderr: stderr)
        }

        guard let output = String(data: outData, encoding: .utf8) else {
            throw WhisperCppError.outputDecodingFailed
        }

        return Transcript(segments: Self.parseSegments(from: output))
    }

    public static func writeTranscript(_ transcript: Transcript, textURL: URL, segmentsJSONLURL: URL) throws {
        try transcript.text.write(to: textURL, atomically: true, encoding: .utf8)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        FileManager.default.createFile(atPath: segmentsJSONLURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: segmentsJSONLURL)
        defer { try? handle.close() }

        for segment in transcript.segments {
            let data = try encoder.encode(segment)
            handle.write(data)
            handle.write(Data("\n".utf8))
        }
        try handle.synchronize()
    }

    private static func parseSegments(from output: String) -> [TranscriptSegment] {
        // Example line:
        // [00:00:00.000 --> 00:00:01.590]   hello
        var segments: [TranscriptSegment] = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("[") else { continue }
            guard let arrowRange = line.range(of: "-->") else { continue }
            guard let closingBracketRange = line.range(of: "]") else { continue }
            guard arrowRange.lowerBound < closingBracketRange.lowerBound else { continue }

            let header = String(line[line.startIndex..<closingBracketRange.upperBound])
            let text = line[closingBracketRange.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }

            // Extract "00:00:00.000" and "00:00:01.590" from header.
            // Header format: [START --> END]
            guard let startOpen = header.firstIndex(of: "[") else { continue }
            guard let endClose = header.firstIndex(of: "]") else { continue }
            let inside = header[header.index(after: startOpen)..<endClose]
            let parts = inside.split(separator: " ")
            // parts: [start, "-->", end]
            guard parts.count >= 3 else { continue }
            let startString = String(parts[0])
            let endString = String(parts[2])

            guard let startMs = parseTimestampMs(startString),
                  let endMs = parseTimestampMs(endString) else {
                continue
            }

            segments.append(TranscriptSegment(startMs: startMs, endMs: endMs, text: text))
        }
        return segments
    }

    private static func parseTimestampMs(_ s: String) -> Int? {
        // hh:mm:ss.mmm
        let parts = s.split(separator: ":")
        guard parts.count == 3 else { return nil }
        guard let hh = Int(parts[0]), let mm = Int(parts[1]) else { return nil }

        let secParts = parts[2].split(separator: ".")
        guard secParts.count == 2 else { return nil }
        guard let ss = Int(secParts[0]) else { return nil }

        // Milliseconds can be 1-3 digits depending on build.
        let msRaw = String(secParts[1])
        let msPadded = msRaw.count >= 3 ? msRaw : msRaw.padding(toLength: 3, withPad: "0", startingAt: 0)
        guard let ms = Int(msPadded.prefix(3)) else { return nil }

        return (((hh * 60 + mm) * 60) + ss) * 1000 + ms
    }
}
