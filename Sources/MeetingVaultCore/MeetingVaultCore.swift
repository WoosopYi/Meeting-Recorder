@preconcurrency import AVFoundation
import Foundation

// MARK: - Session + Paths

public struct RecordingSession: Sendable {
    public let meetingId: String
    public let root: URL
    public let audioRoot: URL
    public let audioChunks: URL
    public let audioFull: URL
    public let eventLog: URL
    public let transcriptRoot: URL
    public let transcriptText: URL
    public let transcriptSegments: URL
    public let notesRoot: URL
    public let notesJSON: URL
    public let notesMarkdown: URL

    public static func create(baseOutput: String?) throws -> RecordingSession {
        let meetingId = UUID().uuidString
        let baseURL: URL
        if let baseOutput {
            baseURL = URL(fileURLWithPath: baseOutput, isDirectory: true)
        } else {
            baseURL = try defaultAppSupportBase()
        }

        let root = baseURL
            .appendingPathComponent("meetings", isDirectory: true)
            .appendingPathComponent(meetingId, isDirectory: true)

        let audioRoot = root.appendingPathComponent("audio", isDirectory: true)
        let audioChunks = audioRoot.appendingPathComponent("chunks", isDirectory: true)
        let audioFull = audioRoot.appendingPathComponent("full.wav")

        let eventsRoot = root.appendingPathComponent("events", isDirectory: true)
        let eventLog = eventsRoot.appendingPathComponent("events.jsonl")

        let transcriptRoot = root.appendingPathComponent("transcript", isDirectory: true)
        let transcriptText = transcriptRoot.appendingPathComponent("transcript.txt")
        let transcriptSegments = transcriptRoot.appendingPathComponent("segments.jsonl")

        let notesRoot = root.appendingPathComponent("notes", isDirectory: true)
        let notesJSON = notesRoot.appendingPathComponent("meeting_notes.json")
        let notesMarkdown = notesRoot.appendingPathComponent("meeting_notes.md")

        try FileManager.default.createDirectory(at: audioChunks, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: eventsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: transcriptRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: notesRoot, withIntermediateDirectories: true)

        return RecordingSession(
            meetingId: meetingId,
            root: root,
            audioRoot: audioRoot,
            audioChunks: audioChunks,
            audioFull: audioFull,
            eventLog: eventLog,
            transcriptRoot: transcriptRoot,
            transcriptText: transcriptText,
            transcriptSegments: transcriptSegments,
            notesRoot: notesRoot,
            notesJSON: notesJSON,
            notesMarkdown: notesMarkdown
        )
    }

    private static func defaultAppSupportBase() throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let appDir = base.appendingPathComponent("MeetingVault", isDirectory: true)
        try fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir
    }
}

// MARK: - Permissions

public enum MicrophonePermission {
    public static func requestIfNeeded() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }
}

// MARK: - Sleep Prevention

public final class SleepInhibitor {
    private let reason: String
    private var activity: NSObjectProtocol?

    public init(reason: String) {
        self.reason = reason
    }

    public func start() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled],
            reason: reason
        )
    }

    public func stop() {
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
    }
}

// MARK: - Event Log (JSONL)

public actor EventLogger {
    public struct Event: Codable, Sendable {
        public enum Level: String, Codable, Sendable {
            case info
            case warn
            case error
        }

        public let at: Date
        public let level: Level
        public let type: String
        public let data: [String: String]
    }

    private let handle: FileHandle
    private let encoder: JSONEncoder

    public init(logURL: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: logURL.path) {
            fm.createFile(atPath: logURL.path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
    }

    deinit {
        try? handle.close()
    }

    public func log(_ event: Event) {
        do {
            let data = try encoder.encode(event)
            handle.write(data)
            handle.write(Data("\n".utf8))
            try handle.synchronize()
        } catch {
            // best-effort; avoid throwing from logging
        }
    }

    public static func info(_ type: String, _ data: [String: String] = [:]) -> Event {
        Event(at: Date(), level: .info, type: type, data: data)
    }

    public static func warn(_ type: String, _ data: [String: String] = [:]) -> Event {
        Event(at: Date(), level: .warn, type: type, data: data)
    }

    public static func error(_ type: String, _ data: [String: String] = [:]) -> Event {
        Event(at: Date(), level: .error, type: type, data: data)
    }
}

// MARK: - Recorder

public struct RecorderIssue: Sendable {
    public enum Kind: String, Sendable {
        case noAudioFrames
        case writeError
        case convertError
    }

    public let kind: Kind
    public let message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }
}

public final class ChunkedMicRecorder {
    private let outputDirectory: URL
    private let fullFileURL: URL?
    private let segmentSeconds: TimeInterval

    private let engine = AVAudioEngine()
    private let writerQueue = DispatchQueue(label: "meetingvault.recorder.writer")

    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    private var currentFile: AVAudioFile?
    private var fullFile: AVAudioFile?
    private var currentChunkIndex: Int = 0
    private var framesWrittenInChunk: AVAudioFramePosition = 0
    private var chunkFrameLimit: AVAudioFramePosition = 0

    private var lastAudioFrameAt = Date.distantPast
    private var watchdog: DispatchSourceTimer?

    private var isRecording: Bool = false

    public var onEvent: ((EventLogger.Event) -> Void)?
    public var onIssue: ((RecorderIssue) -> Void)?

    public init(outputDirectory: URL, fullFileURL: URL?, segmentSeconds: TimeInterval) {
        self.outputDirectory = outputDirectory
        self.fullFileURL = fullFileURL
        self.segmentSeconds = segmentSeconds
    }

    public func start() throws {
        guard !isRecording else { return }
        isRecording = true

        onEvent?(EventLogger.info("recording_started"))

        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        self.inputFormat = inputFormat

        // Target a Whisper-friendly format for later STT.
        let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )

        self.outputFormat = outFormat
        if let outFormat {
            self.converter = AVAudioConverter(from: inputFormat, to: outFormat)
            self.chunkFrameLimit = AVAudioFramePosition(outFormat.sampleRate * segmentSeconds)
        } else {
            self.converter = nil
            self.chunkFrameLimit = AVAudioFramePosition(inputFormat.sampleRate * segmentSeconds)
        }

        try openFullFileIfNeeded()
        try rotateChunkFile()

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let copied = buffer.copyForAsync()
            self.writerQueue.async {
                self.handle(buffer: copied)
            }
        }

        try engine.start()
        startWatchdog()
    }

    public func stop() {
        guard isRecording else { return }
        isRecording = false

        onEvent?(EventLogger.info("recording_stopped"))

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        watchdog?.cancel()
        watchdog = nil

        writerQueue.sync {
            self.currentFile = nil
            self.fullFile = nil
        }
    }

    private func handle(buffer: AVAudioPCMBuffer?) {
        guard isRecording else { return }
        guard let buffer else { return }

        lastAudioFrameAt = Date()

        do {
            let outBuffer: AVAudioPCMBuffer
            if let converter, let outputFormat {
                guard let converted = buffer.converted(to: outputFormat, using: converter) else {
                    onIssue?(RecorderIssue(kind: .convertError, message: "Failed to convert audio buffer"))
                    return
                }
                outBuffer = converted
            } else {
                outBuffer = buffer
            }

            if framesWrittenInChunk + AVAudioFramePosition(outBuffer.frameLength) >= chunkFrameLimit {
                try rotateChunkFile()
            }

            try currentFile?.write(from: outBuffer)
            try fullFile?.write(from: outBuffer)
            framesWrittenInChunk += AVAudioFramePosition(outBuffer.frameLength)
        } catch {
            let msg = "Write failed: \(error.localizedDescription)"
            fputs("recording error: \(msg)\n", stderr)
            onIssue?(RecorderIssue(kind: .writeError, message: msg))
        }
    }

    private func openFullFileIfNeeded() throws {
        guard let fullFileURL else { return }
        guard fullFile == nil else { return }
        let format = outputFormat ?? inputFormat
        guard let format else {
            throw NSError(domain: "meetingvault", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing audio format"]) 
        }
        fullFile = try AVAudioFile(
            forWriting: fullFileURL,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        onEvent?(EventLogger.info("full_file_opened", ["path": fullFileURL.path]))
    }

    private func rotateChunkFile() throws {
        currentChunkIndex += 1
        framesWrittenInChunk = 0

        let filename = String(format: "%06d.wav", currentChunkIndex)
        let url = outputDirectory.appendingPathComponent(filename)

        let format = outputFormat ?? inputFormat
        guard let format else {
            throw NSError(domain: "meetingvault", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing audio format"]) 
        }

        currentFile = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        onEvent?(EventLogger.info("chunk_started", [
            "index": String(currentChunkIndex),
            "path": url.path,
        ]))
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.isRecording else { return }
            let silence = Date().timeIntervalSince(self.lastAudioFrameAt)
            if silence > 3 {
                self.onIssue?(RecorderIssue(
                    kind: .noAudioFrames,
                    message: "No audio frames for \(String(format: "%.1f", silence))s (check microphone input)"
                ))
            }
        }
        timer.resume()
        watchdog = timer
    }
}

// MARK: - Audio Helpers

private extension AVAudioPCMBuffer {
    func copyForAsync() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            return nil
        }
        copy.frameLength = frameLength

        // AVAudioEngine typically delivers float PCM. Handle that first.
        if let src = floatChannelData, let dst = copy.floatChannelData {
            let channels = Int(format.channelCount)
            let byteCount = Int(frameLength) * MemoryLayout<Float>.size
            for ch in 0..<channels {
                memcpy(dst[ch], src[ch], byteCount)
            }
            return copy
        }

        if let src = int16ChannelData, let dst = copy.int16ChannelData {
            let channels = Int(format.channelCount)
            let byteCount = Int(frameLength) * MemoryLayout<Int16>.size
            for ch in 0..<channels {
                memcpy(dst[ch], src[ch], byteCount)
            }
            return copy
        }

        // Unknown backing; give up.
        return nil
    }

    func converted(to outputFormat: AVAudioFormat, using converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / format.sampleRate
        let outCapacity = max(1, AVAudioFrameCount(Double(frameLength) * ratio) + 1)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outCapacity) else {
            return nil
        }

        final class ConsumedFlag: @unchecked Sendable {
            var value: Bool
            init(_ value: Bool) { self.value = value }
        }

        let inputBuffer = self
        let consumed = ConsumedFlag(false)
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if consumed.value {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed.value = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        var error: NSError?
        converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
        if let error {
            fputs("convert error: \(error)\n", stderr)
            return nil
        }
        return outBuffer
    }
}
