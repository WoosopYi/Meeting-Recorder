import Foundation

public enum MeetingNotesPrompts {
    public static func summarizePrompt(transcript: String) -> String {
        // Keep the prompt stable and easy to parse.
        return """
You are an assistant that writes concise, structured meeting notes for a B2B sales meeting.

Return ONLY valid JSON (no markdown, no backticks, no extra text) that matches this exact schema:
{
  "title": "string or null",
  "summary": "string",
  "decisions": ["string"],
  "actionItems": [{"task":"string","owner":"string or null","due":"string or null"}],
  "openQuestions": ["string"],
  "followUpEmail": "string or null"
}

Rules:
- Use Korean for the content if the transcript is mostly Korean.
- Keep summary to 8-12 bullet-like sentences in plain text (not actual JSON array).
- Decisions must be concrete.
- Action items must be actionable and specific.

Transcript:
<<<
\(transcript)
>>>
"""
    }
}
