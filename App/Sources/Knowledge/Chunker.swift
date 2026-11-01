import Foundation

/// Cuts text into passages of roughly 900 characters on paragraph and sentence boundaries,
/// with a short overlap so an answer that straddles a boundary is still found.
enum Chunker {
    static func split(_ text: String, target: Int = 900, overlap: Int = 150) -> [String] {
        let clean = text.replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }

        var units: [String] = []
        for paragraph in clean.components(separatedBy: "\n\n") {
            let p = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if p.isEmpty { continue }
            units += p.count <= target ? [p] : pack(sentences(of: p), limit: target)
        }

        var chunks: [String] = []
        var current = ""
        for unit in units {
            if !current.isEmpty, current.count + unit.count + 2 > target {
                chunks.append(current)
                current = tail(of: current, overlap)
            }
            current += (current.isEmpty ? "" : "\n\n") + unit
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { chunks.append(current) }
        return chunks
    }

    private static func sentences(of text: String) -> [String] {
        var result: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .substringNotRequired]) { _, range, _, _ in
            result.append(String(text[range]))
        }
        return result.isEmpty ? [text] : result
    }

    /// Joins sentences up to `limit`; one over-long sentence is cut at word boundaries.
    private static func pack(_ parts: [String], limit: Int) -> [String] {
        var out: [String] = []
        var current = ""
        func flush() { let t = current.trimmingCharacters(in: .whitespacesAndNewlines); if !t.isEmpty { out.append(t) }; current = "" }
        for part in parts {
            if part.count > limit {
                flush()
                var piece = ""
                for word in part.split(separator: " ", omittingEmptySubsequences: true) {
                    if piece.count + word.count + 1 > limit { out.append(piece); piece = "" }
                    piece += (piece.isEmpty ? "" : " ") + word
                }
                current = piece
            } else if current.count + part.count > limit {
                flush(); current = part
            } else {
                current += part
            }
        }
        flush()
        return out
    }

    private static func tail(of text: String, _ count: Int) -> String {
        guard text.count > count else { return "" }
        let slice = String(text.suffix(count))
        if let space = slice.firstIndex(of: " ") { return String(slice[slice.index(after: space)...]) }
        return slice
    }
}
