import Foundation

public struct MeetingNotes: Codable, Sendable {
    public struct ActionItem: Codable, Sendable {
        public let task: String
        public let owner: String?
        public let due: String?

        public init(task: String, owner: String? = nil, due: String? = nil) {
            self.task = task
            self.owner = owner
            self.due = due
        }
    }

    public let title: String?
    public let summary: String
    public let decisions: [String]
    public let actionItems: [ActionItem]
    public let openQuestions: [String]
    public let followUpEmail: String?

    public init(
        title: String? = nil,
        summary: String,
        decisions: [String] = [],
        actionItems: [ActionItem] = [],
        openQuestions: [String] = [],
        followUpEmail: String? = nil
    ) {
        self.title = title
        self.summary = summary
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.followUpEmail = followUpEmail
    }
}
