import AppKit
import Foundation
import MeetingVaultCore

@MainActor
final class MeetingVaultApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var toggleRecordingItem: NSMenuItem!
    private var openLastFolderItem: NSMenuItem!
    private var processLastMeetingItem: NSMenuItem!

    private var recorder: ChunkedMicRecorder?
    private var session: RecordingSession?
    private var eventLogger: EventLogger?

    private var notesWindowController: NotesReviewWindowController?

    private var config: AppConfig = ConfigStore.load()

    private let notifier = LocalNotifier()
    private let sleepInhibitor = SleepInhibitor(reason: "MeetingVault recording")
    private let hotKeys = HotKeyManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()

        ensureConfigFileExistsAndPrintLocation()

        do {
            try hotKeys.registerToggleRecording { [weak self] in
                Task { @MainActor in
                    self?.toggleRecording()
                }
            }
        } catch {
            // best-effort: the app still works without hotkeys
        }
    }

    private func ensureConfigFileExistsAndPrintLocation() {
        do {
            var config = ConfigStore.load()
            if config.geminiModel == nil {
                config.geminiModel = "gemini-3-flash-preview"
            }
            try ConfigStore.save(config)
            self.config = config

            let url = try ConfigStore.defaultURL()
            print("MeetingVault running (menubar icon: MV). Config: \(url.path)")
        } catch {
            print("MeetingVault running, but failed to create/open config: \(error)")
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "MV"

        let menu = NSMenu()

        toggleRecordingItem = NSMenuItem(
            title: "Start Recording",
            action: #selector(toggleRecording),
            keyEquivalent: "r"
        )
        toggleRecordingItem.target = self
        menu.addItem(toggleRecordingItem)

        openLastFolderItem = NSMenuItem(
            title: "Open Last Recording Folder",
            action: #selector(openLastFolder),
            keyEquivalent: ""
        )
        openLastFolderItem.target = self
        openLastFolderItem.isEnabled = false
        menu.addItem(openLastFolderItem)

        processLastMeetingItem = NSMenuItem(
            title: "Process Last Meeting (Transcript + Gemini)",
            action: #selector(processLastMeeting),
            keyEquivalent: ""
        )
        processLastMeetingItem.target = self
        processLastMeetingItem.isEnabled = false
        menu.addItem(processLastMeetingItem)

        let openConfig = NSMenuItem(
            title: "Open Config File",
            action: #selector(openConfigFile),
            keyEquivalent: ""
        )
        openConfig.target = self
        menu.addItem(openConfig)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func toggleRecording() {
        if recorder == nil {
            startRecording()
        } else {
            stopRecording()
        }
    }

    private func startRecording() {
        Task { @MainActor in
            let granted = await MicrophonePermission.requestIfNeeded()
            guard granted else {
                notifier.notify(title: "MeetingVault", body: "Microphone permission denied")
                return
            }

            do {
                let session = try RecordingSession.create(baseOutput: nil)
                let eventLogger = try EventLogger(logURL: session.eventLog)
                self.session = session
                self.eventLogger = eventLogger

                await eventLogger.log(EventLogger.info("recording_session_created", [
                    "meeting_id": session.meetingId,
                    "root": session.root.path,
                ]))

                sleepInhibitor.start()

                let recorder = ChunkedMicRecorder(
                    outputDirectory: session.audioChunks,
                    fullFileURL: session.audioFull,
                    segmentSeconds: 30
                )

                recorder.onEvent = { event in
                    Task { await eventLogger.log(event) }
                }
                recorder.onIssue = { [weak self] issue in
                    Task { @MainActor in
                        guard let self else { return }
                        await eventLogger.log(EventLogger.warn(issue.kind.rawValue, [
                            "message": issue.message
                        ]))
                        self.notifier.notify(
                            title: "MeetingVault recording issue",
                            body: issue.message
                        )
                    }
                }

                try recorder.start()
                self.recorder = recorder
                updateStatus(isRecording: true)
                openLastFolderItem.isEnabled = true
                processLastMeetingItem.isEnabled = false
            } catch {
                sleepInhibitor.stop()
                notifier.notify(title: "MeetingVault", body: "Failed to start recording: \(error)")
            }
        }
    }

    private func stopRecording() {
        recorder?.stop()
        recorder = nil
        sleepInhibitor.stop()
        updateStatus(isRecording: false)
        processLastMeetingItem.isEnabled = (session != nil)
    }

    private func updateStatus(isRecording: Bool) {
        toggleRecordingItem.title = isRecording ? "Stop Recording" : "Start Recording"
        statusItem.button?.title = isRecording ? "REC" : "MV"
    }

    @objc private func openLastFolder() {
        guard let session else { return }
        NSWorkspace.shared.open(session.root)
    }

    @objc private func openConfigFile() {
        do {
            // Ensure the file exists with a starter template.
            if config.geminiModel == nil {
                config.geminiModel = "gemini-3-flash-preview"
            }
            try ConfigStore.save(config)
            let url = try ConfigStore.defaultURL()
            NSWorkspace.shared.open(url)
        } catch {
            // best-effort
        }
    }

    @objc private func quitApp() {
        stopRecording()
        NSApp.terminate(nil)
    }

    @objc private func processLastMeeting() {
        guard recorder == nil else { return }
        guard let session else { return }

        // Reload config from disk so edits take effect immediately.
        let config = ConfigStore.load()
        let logger = eventLogger

        processLastMeetingItem.isEnabled = false

        // Show a window immediately so the user sees progress.
        let placeholder = """
# Generating Notes

Meeting ID: \(session.meetingId)

- Transcribing (Whisper)
- Summarizing (Gemini)
- Writing notes (JSON + Markdown)

This can take a few minutes depending on model size.
"""
        presentNotesWindow(markdown: placeholder, notesFolderURL: session.notesRoot, jsonURL: session.notesJSON)

        Task.detached { [session, config, logger] in
            do {
                if let logger {
                    await logger.log(EventLogger.info("pipeline_started"))
                }

                _ = try await MeetingPipeline.process(session: session, config: config)
                if let logger {
                    await logger.log(EventLogger.info("pipeline_finished"))
                }

                let markdown = (try? String(contentsOf: session.notesMarkdown, encoding: .utf8)) ?? ""
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.notesWindowController?.setMarkdown(markdown)
                    self.notesWindowController?.showWindow(nil)
                    self.notesWindowController?.window?.makeKeyAndOrderFront(nil)
                    self.notesWindowController?.window?.orderFrontRegardless()
                    NSApp.activate(ignoringOtherApps: true)
                    self.processLastMeetingItem.isEnabled = (self.session != nil)
                }
            } catch {
                if let logger {
                    await logger.log(EventLogger.error("pipeline_failed", [
                        "error": String(describing: error)
                    ]))
                }

                let errorText = """
# Processing Failed

\(String(describing: error))

## What to check
- `config.json` has a valid `whisperModelPath`
- `config.json` has a valid `geminiApiKey`
- Network is available for Gemini
"""

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.notesWindowController?.setMarkdown(errorText)
                    self.notesWindowController?.showWindow(nil)
                    self.notesWindowController?.window?.makeKeyAndOrderFront(nil)
                    self.notesWindowController?.window?.orderFrontRegardless()
                    NSApp.activate(ignoringOtherApps: true)
                    self.notifier.notify(title: "MeetingVault", body: String(describing: error))
                    self.processLastMeetingItem.isEnabled = (self.session != nil)
                }
            }
        }
    }

    private func presentNotesWindow(markdown: String, notesFolderURL: URL, jsonURL: URL?) {
        let title = "MeetingVault — Notes"
        let controller = NotesReviewWindowController(
            title: title,
            markdown: markdown,
            notesFolderURL: notesFolderURL,
            jsonURL: jsonURL
        )
        self.notesWindowController = controller

        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.orderFrontRegardless()
    }
}

final class LocalNotifier {
    func notify(title: String, body: String) {
        // When running via `swift run` we don't have a real .app bundle, and
        // UNUserNotificationCenter can crash. Use AppleScript notifications.
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
