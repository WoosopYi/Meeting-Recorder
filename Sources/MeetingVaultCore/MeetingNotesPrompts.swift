import Foundation

public enum MeetingNotesPrompts {
    public static func summarizePrompt(transcript: String) -> String {
        // Keep the prompt stable and easy to parse.
        return """
You are an assistant that writes structured, fact-based meeting notes.

Return ONLY valid JSON (no markdown, no backticks, no extra text) that matches this exact schema:
{
  "title": "string or null",
  "summary": ["string"],
  "decisions": ["string"],
  "actionItems": [{"task":"string","owner":"string or null","due":"string or null"}],
  "openQuestions": ["string"],
  "followUpEmail": "string or null"
}

Rules:
- Use Korean if the transcript is mostly Korean.
- ONLY use facts stated in the transcript. Do NOT guess, assume, or add generic filler.
- If something is not clearly in the transcript, omit it or use null/empty.

Formatting rules:
- For summary/decisions/openQuestions arrays: each item must be plain text (do NOT include leading '-' or numbering).
- Prefer adding a timestamp range at the start of each item if available in the transcript, e.g. "[00:12:03.120-00:12:10.500] ...".
- Keep items short and readable (1-2 sentences max).

Action items:
- Make them specific and executable.
- Set owner/due to null unless explicitly stated in the transcript.

Transcript:
<<<
\(transcript)
>>>
"""
    }
}
