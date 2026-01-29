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

        NotificationCenter.default.addObserver(
            forName: .meetingVaultPipelineFinished,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self else { return }

                if let error = note.userInfo?["error"] as? String {
                    await self.notifier.notify(title: "MeetingVault", body: error)
                    self.processLastMeetingItem.isEnabled = (self.session != nil)
                    return
                }

                guard let markdownPath = note.userInfo?["notes_markdown_path"] as? String,
                      let notesFolderPath = note.userInfo?["notes_folder_path"] as? String else {
                    await self.notifier.notify(title: "MeetingVault", body: "Processing complete")
                    self.processLastMeetingItem.isEnabled = (self.session != nil)
                    return
                }

                let markdownURL = URL(fileURLWithPath: markdownPath)
                let notesFolderURL = URL(fileURLWithPath: notesFolderPath, isDirectory: true)
                let jsonURL = (note.userInfo?["notes_json_path"] as? String).map { URL(fileURLWithPath: $0) }

                let markdown = (try? String(contentsOf: markdownURL, encoding: .utf8)) ?? ""

                self.presentNotesWindow(markdown: markdown, notesFolderURL: notesFolderURL, jsonURL: jsonURL)
                self.processLastMeetingItem.isEnabled = (self.session != nil)
            }
        }

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
                await notifier.notify(title: "MeetingVault", body: "Microphone permission denied")
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
                        await self.notifier.notify(
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
                await notifier.notify(title: "MeetingVault", body: "Failed to start recording: \(error)")
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

        Task.detached {
            do {
                if let logger {
                    await logger.log(EventLogger.info("pipeline_started"))
                }

                _ = try await MeetingPipeline.process(session: session, config: config)
                if let logger {
                    await logger.log(EventLogger.info("pipeline_finished"))
                }
                NotificationCenter.default.post(
                    name: .meetingVaultPipelineFinished,
                    object: nil,
                    userInfo: [
                        "meeting_id": session.meetingId,
                        "notes_folder_path": session.notesRoot.path,
                        "notes_json_path": session.notesJSON.path,
                        "notes_markdown_path": session.notesMarkdown.path,
                    ]
                )
            } catch {
                if let logger {
                    await logger.log(EventLogger.error("pipeline_failed", [
                        "error": String(describing: error)
                    ]))
                }
                NotificationCenter.default.post(
                    name: .meetingVaultPipelineFinished,
                    object: nil,
                    userInfo: ["error": String(describing: error)]
                )
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
    }
}

extension Notification.Name {
    static let meetingVaultPipelineFinished = Notification.Name("meetingVault.pipelineFinished")
}

@MainActor
final class LocalNotifier {
    func notify(title: String, body: String) async {
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
