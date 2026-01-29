import Foundation

public enum NotionError: LocalizedError {
    case missingToken
    case httpError(status: Int, body: String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            return "Missing Notion token"
        case let .httpError(status, body):
            return "Notion HTTP \(status): \(body)"
        case let .invalidResponse(message):
            return "Notion response error: \(message)"
        }
    }
}

public final class NotionClient {
    public let token: String
    public let notionVersion: String

    private let urlSession: URLSession

    public init(token: String, notionVersion: String = "2022-06-28", urlSession: URLSession = .shared) {
        self.token = token
        self.notionVersion = notionVersion
        self.urlSession = urlSession
    }

    public func createMeetingPage(databaseId: String, title: String, notes: MeetingNotes) async throws -> String {
        guard !token.isEmpty else { throw NotionError.missingToken }

        let url = URL(string: "https://api.notion.com/v1/pages")!
        let payload: [String: Any] = [
            "parent": ["database_id": databaseId],
            "properties": [
                "Name": [
                    "title": [
                        ["type": "text", "text": ["content": title]]
                    ]
                ]
            ]
        ]

        let data = try await requestJSON(method: "POST", url: url, body: payload)
        let json = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = json as? [String: Any], let id = dict["id"] as? String else {
            throw NotionError.invalidResponse("Missing page id")
        }

        // Append blocks.
        try await appendMeetingBlocks(pageId: id, notes: notes)
        return id
    }

    public func appendMeetingBlocks(pageId: String, notes: MeetingNotes) async throws {
        let blocks = NotionBlockBuilder.blocks(for: notes)
        try await appendBlocks(blockId: pageId, children: blocks)
    }

    public func appendBlocks(blockId: String, children: [[String: Any]]) async throws {
        guard !token.isEmpty else { throw NotionError.missingToken }
        guard !children.isEmpty else { return }

        // Notion API max 100 children per request.
        let chunkSize = 100
        var index = 0
        while index < children.count {
            let chunk = Array(children[index..<min(index + chunkSize, children.count)])
            let url = URL(string: "https://api.notion.com/v1/blocks/\(blockId)/children")!
            let payload: [String: Any] = [
                "children": chunk
            ]
            _ = try await requestJSON(method: "PATCH", url: url, body: payload)
            index += chunkSize
        }
    }

    private func requestJSON(method: String, url: URL, body: [String: Any]) async throws -> Data {
        let bodyData = try JSONSerialization.data(withJSONObject: body, options: [])
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(notionVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        // Simple retry for 429.
        for attempt in 0..<3 {
            let (data, response) = try await urlSession.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? -1
            if status == 429, attempt < 2 {
                let retryAfter = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 1.0
                try await Task.sleep(nanoseconds: UInt64(max(1.0, retryAfter) * 1_000_000_000))
                continue
            }
            guard (200...299).contains(status) else {
                let bodyText = String(data: data, encoding: .utf8) ?? ""
                throw NotionError.httpError(status: status, body: bodyText)
            }
            return data
        }

        throw NotionError.httpError(status: 429, body: "Rate limited")
    }
}

enum NotionBlockBuilder {
    static func blocks(for notes: MeetingNotes) -> [[String: Any]] {
        var blocks: [[String: Any]] = []

        blocks.append(heading2("Summary"))
        blocks.append(paragraph(notes.summary))

        if !notes.decisions.isEmpty {
            blocks.append(heading2("Decisions"))
            for item in notes.decisions {
                blocks.append(bulleted(item))
            }
        }

        if !notes.actionItems.isEmpty {
            blocks.append(heading2("Action Items"))
            for item in notes.actionItems {
                let title = formatActionItem(item)
                blocks.append(todo(title, checked: false))
            }
        }

        if !notes.openQuestions.isEmpty {
            blocks.append(heading2("Open Questions"))
            for item in notes.openQuestions {
                blocks.append(bulleted(item))
            }
        }

        if let email = notes.followUpEmail, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(heading2("Follow-up Email"))
            blocks.append(paragraph(email))
        }

        return blocks
    }

    private static func heading2(_ text: String) -> [String: Any] {
        [
            "object": "block",
            "type": "heading_2",
            "heading_2": [
                "rich_text": [richText(text)]
            ]
        ]
    }

    private static func paragraph(_ text: String) -> [String: Any] {
        [
            "object": "block",
            "type": "paragraph",
            "paragraph": [
                "rich_text": [richText(text)]
            ]
        ]
    }

    private static func bulleted(_ text: String) -> [String: Any] {
        [
            "object": "block",
            "type": "bulleted_list_item",
            "bulleted_list_item": [
                "rich_text": [richText(text)]
            ]
        ]
    }

    private static func todo(_ text: String, checked: Bool) -> [String: Any] {
        [
            "object": "block",
            "type": "to_do",
            "to_do": [
                "rich_text": [richText(text)],
                "checked": checked
            ]
        ]
    }

    private static func richText(_ text: String) -> [String: Any] {
        [
            "type": "text",
            "text": [
                "content": text
            ]
        ]
    }

    private static func formatActionItem(_ item: MeetingNotes.ActionItem) -> String {
        var parts: [String] = [item.task]
        if let owner = item.owner, !owner.isEmpty {
            parts.append("Owner: \(owner)")
        }
        if let due = item.due, !due.isEmpty {
            parts.append("Due: \(due)")
        }
        return parts.joined(separator: " | ")
    }
}
