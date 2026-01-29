import Foundation

public enum GeminiError: LocalizedError {
    case missingAPIKey
    case httpError(status: Int, body: String)
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Missing Gemini API key"
        case let .httpError(status, body):
            return "Gemini HTTP \(status): \(body)"
        case .emptyResponse:
            return "Gemini response missing text"
        }
    }
}

public final class GeminiClient {
    public let apiKey: String
    public let model: String

    private let urlSession: URLSession

    /// Uses Google AI Studio / Gemini API (generativelanguage.googleapis.com).
    public init(apiKey: String, model: String = "gemini-3-flash-preview", urlSession: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.urlSession = urlSession
    }

    public func generateText(prompt: String) async throws -> String {
        guard !apiKey.isEmpty else { throw GeminiError.missingAPIKey }

        var urlComponents = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")
        urlComponents?.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = urlComponents?.url else {
            throw GeminiError.httpError(status: -1, body: "Invalid URL")
        }

        let body: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        ["text": prompt]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.2
            ]
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body, options: [])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        let (data, response) = try await urlSession.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? -1

        guard (200...299).contains(status) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw GeminiError.httpError(status: status, body: bodyText)
        }

        // Parse minimal response:
        // candidates[0].content.parts[0].text
        let json = try JSONSerialization.jsonObject(with: data, options: [])
        guard
            let dict = json as? [String: Any],
            let candidates = dict["candidates"] as? [[String: Any]],
            let first = candidates.first,
            let content = first["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]],
            let firstPart = parts.first,
            let text = firstPart["text"] as? String
        else {
            throw GeminiError.emptyResponse
        }

        return text
    }
}
