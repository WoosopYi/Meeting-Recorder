import Foundation

public struct AppConfig: Codable, Sendable {
    public var whisperBinary: String?
    public var whisperModelPath: String?
    public var whisperLanguage: String?

    public var geminiApiKey: String?
    public var geminiModel: String?

    public var notionToken: String?
    public var notionDatabaseId: String?

    public init(
        whisperBinary: String? = nil,
        whisperModelPath: String? = nil,
        whisperLanguage: String? = nil,
        geminiApiKey: String? = nil,
        geminiModel: String? = nil,
        notionToken: String? = nil,
        notionDatabaseId: String? = nil
    ) {
        self.whisperBinary = whisperBinary
        self.whisperModelPath = whisperModelPath
        self.whisperLanguage = whisperLanguage
        self.geminiApiKey = geminiApiKey
        self.geminiModel = geminiModel
        self.notionToken = notionToken
        self.notionDatabaseId = notionDatabaseId
    }
}

public enum ConfigStore {
    public static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("MeetingVault", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    public static func load() -> AppConfig {
        do {
            let url = try defaultURL()
            guard FileManager.default.fileExists(atPath: url.path) else {
                return AppConfig()
            }
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            return AppConfig()
        }
    }

    public static func save(_ config: AppConfig) throws {
        let url = try defaultURL()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: url, options: [.atomic])
    }
}
