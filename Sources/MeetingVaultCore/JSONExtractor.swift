import Foundation

public enum JSONExtractor {
    /// Extracts the first top-level JSON object (`{...}`) from a text blob.
    /// Handles braces inside JSON strings and nested objects.
    public static func extractFirstJSONObject(from text: String) -> String? {
        var startIndex: String.Index?
        var depth = 0
        var inString = false
        var escaped = false

        for i in text.indices {
            let ch = text[i]

            if startIndex == nil {
                if ch == "{" {
                    startIndex = i
                    depth = 1
                }
                continue
            }

            if inString {
                if escaped {
                    escaped = false
                    continue
                }
                if ch == "\\" {
                    escaped = true
                    continue
                }
                if ch == "\"" {
                    inString = false
                }
                continue
            }

            if ch == "\"" {
                inString = true
                continue
            }

            if ch == "{" {
                depth += 1
                continue
            }

            if ch == "}" {
                depth -= 1
                if depth == 0, let startIndex {
                    return String(text[startIndex...i])
                }
            }
        }

        return nil
    }
}
