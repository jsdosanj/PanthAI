import Foundation

/// Removes things that look like secrets from text before it goes to a model or is saved in a chat.
enum Redactor {
    private static let patterns: [(String, String)] = [
        (#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#, "[private key removed]"),
        (#"\bgh[pousr]_[A-Za-z0-9]{30,}\b"#, "[GitHub token removed]"),
        (#"\bgithub_pat_[A-Za-z0-9_]{40,}\b"#, "[GitHub token removed]"),
        (#"\bsk-(?:ant-|proj-)?[A-Za-z0-9_\-]{24,}\b"#, "[API key removed]"),
        (#"\bAKIA[0-9A-Z]{16}\b"#, "[AWS key removed]"),
        (#"\bxox[baprs]-[A-Za-z0-9\-]{10,}\b"#, "[Slack token removed]"),
        (#"(?i)\b(bearer)\s+[A-Za-z0-9._\-]{20,}"#, "$1 [token removed]"),
        (#"(?i)\b(password|passwd|secret|api[_-]?key|token)\s*[:=]\s*['\"]?[^\s'\"]{8,}"#, "$1=[removed]"),
    ]

    static func clean(_ text: String) -> String {
        patterns.reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1, options: .regularExpression) }
    }
}
