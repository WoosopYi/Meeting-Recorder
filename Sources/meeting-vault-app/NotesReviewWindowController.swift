import AppKit
import Foundation

final class NotesReviewWindowController: NSWindowController {
    private let notesFolderURL: URL
    private let jsonURL: URL?
    private let textView = NSTextView()

    init(title: String, markdown: String, notesFolderURL: URL, jsonURL: URL?) {
        self.notesFolderURL = notesFolderURL
        self.jsonURL = jsonURL

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false

        super.init(window: window)

        setupUI(markdown: markdown)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI(markdown: String) {
        guard let window else { return }

        let contentView = NSView()
        window.contentView = contentView

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesRuler = false
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.string = markdown

        scrollView.documentView = textView

        let buttonStack = NSStackView()
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8
        buttonStack.alignment = .centerY

        let copyButton = NSButton(title: "Copy", target: self, action: #selector(copyMarkdown))
        let copyJSONButton = NSButton(title: "Copy JSON", target: self, action: #selector(copyJSON))
        let revealButton = NSButton(title: "Reveal Folder", target: self, action: #selector(revealFolder))
        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeWindow))

        buttonStack.addArrangedSubview(copyButton)
        buttonStack.addArrangedSubview(copyJSONButton)
        buttonStack.addArrangedSubview(revealButton)
        buttonStack.addArrangedSubview(NSView())
        buttonStack.addArrangedSubview(closeButton)

        contentView.addSubview(scrollView)
        contentView.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),

            buttonStack.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 10),
            buttonStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            buttonStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            buttonStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            buttonStack.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    @objc private func copyMarkdown() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(textView.string, forType: .string)
    }

    @objc private func copyJSON() {
        guard let jsonURL else { return }
        guard let data = try? Data(contentsOf: jsonURL),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    @objc private func revealFolder() {
        NSWorkspace.shared.open(notesFolderURL)
    }

    @objc private func closeWindow() {
        close()
    }
}
