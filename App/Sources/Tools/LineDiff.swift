import Foundation

struct DiffLine: Identifiable, Sendable {
    enum Kind: Sendable { case same, added, removed }
    let id = UUID()
    let kind: Kind
    let text: String
}

enum LineDiff {
    /// LCS line diff with 3 lines of context. Fine for files up to a few thousand lines.
    static func compute(before: String?, after: String, context: Int = 3) -> [DiffLine] {
        let a = (before ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let b = after.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard a.count * b.count <= 6_000_000 else {
            return [DiffLine(kind: .removed, text: "(\(a.count) lines)"), DiffLine(kind: .added, text: "(\(b.count) lines — too large to diff)")]
        }
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var all: [DiffLine] = []
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { all.append(.init(kind: .same, text: a[i])); i += 1; j += 1 }
            else if table[i + 1][j] >= table[i][j + 1] { all.append(.init(kind: .removed, text: a[i])); i += 1 }
            else { all.append(.init(kind: .added, text: b[j])); j += 1 }
        }
        while i < a.count { all.append(.init(kind: .removed, text: a[i])); i += 1 }
        while j < b.count { all.append(.init(kind: .added, text: b[j])); j += 1 }

        // Keep only changed lines plus context.
        var keep = Set<Int>()
        for (index, line) in all.enumerated() where line.kind != .same {
            for k in max(0, index - context)...min(all.count - 1, index + context) { keep.insert(k) }
        }
        return all.enumerated().filter { keep.contains($0.offset) }.map(\.element)
    }
}
