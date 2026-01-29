import Foundation

public enum MeetingNotesMarkdown {
    public static func render(meetingId: String, notes: MeetingNotes) -> String {
        var lines: [String] = []

        let title = (notes.title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        lines.append("# \(title ?? "Meeting Notes")")
        lines.append("")
        lines.append("Meeting ID: \(meetingId)")

        lines.append("")
        lines.append("## Summary")
        if notes.summary.isEmpty {
            lines.append("- (empty)")
        } else {
            for item in notes.summary {
                let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                lines.append("- \(trimmed)")
            }
        }

        if !notes.decisions.isEmpty {
            lines.append("")
            lines.append("## Decisions")
            for item in notes.decisions {
                let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                lines.append("- \(trimmed)")
            }
        }

        if !notes.actionItems.isEmpty {
            lines.append("")
            lines.append("## Action Items")
            for item in notes.actionItems {
                lines.append("- [ ] \(formatActionItem(item))")
            }
        }

        if !notes.openQuestions.isEmpty {
            lines.append("")
            lines.append("## Open Questions")
            for item in notes.openQuestions {
                let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                lines.append("- \(trimmed)")
            }
        }

        if let followUpEmail = notes.followUpEmail?.trimmingCharacters(in: .whitespacesAndNewlines),
           !followUpEmail.isEmpty {
            lines.append("")
            lines.append("## Follow-up Email")
            lines.append(followUpEmail)
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func formatActionItem(_ item: MeetingNotes.ActionItem) -> String {
        var parts: [String] = [item.task]
        if let owner = item.owner?.trimmingCharacters(in: .whitespacesAndNewlines), !owner.isEmpty {
            parts.append("Owner: \(owner)")
        }
        if let due = item.due?.trimmingCharacters(in: .whitespacesAndNewlines), !due.isEmpty {
            parts.append("Due: \(due)")
        }
        return parts.joined(separator: " | ")
    }
}
