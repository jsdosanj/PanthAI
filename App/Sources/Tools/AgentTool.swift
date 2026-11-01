import Foundation

enum ToolRisk: String, Sendable, Codable {
    case read          // never changes anything
    case write         // edits files in the workspace (checkpointed, undoable)
    case network       // outbound read-only request
    case networkWrite  // outbound request that can change something remote
    case execute       // runs code in the sandbox (no files, no network)
    case remote        // git push, PRs, MCP tools: changes things off-device
}

enum NetworkMode: String, CaseIterable, Identifiable, Sendable {
    case full, custom, ask, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .full: "Full access"
        case .custom: "Only allowed sites"
        case .ask: "Ask each time"
        case .off: "Off"
        }
    }
}

enum NetworkPolicy {
    /// Whether a request to `url` may go out under the session's network setting.
    static func allows(_ url: URL, mode: NetworkMode, allowedHosts: [String]) -> Bool {
        switch mode {
        case .off: return false
        case .full, .ask: return true
        case .custom:
            guard let host = url.host?.lowercased() else { return false }
            return allowedHosts.contains { host == $0 || host.hasSuffix("." + $0) }
        }
    }
}

/// What a tool may touch. Plain values only, so tools can run off the main actor.
struct ToolContext: Sendable {
    var workspaceRoot: URL?
    var workspaceFullName: String?
    var workspaceBranch: String?
    var networkMode: NetworkMode = .full
    var allowedHosts: [String] = []
    var sshHost: SSHHostSnapshot?
    var memoryAgentID: UUID?
    var memoryEnabled = true
}

struct ToolOutput: Sendable {
    var text: String
    var change: FileChange?
}

struct FileChange: Sendable, Equatable {
    /// "workspace" (the attached repo) or "documents" (the Files app folder).
    var scope: String = "workspace"
    var path: String
    var before: String?
    var after: String
}

struct ToolSpec: Sendable {
    let name: String
    let summary: String
    let parameters: String         // e.g. "path: string, start_line?: number"
    let risk: ToolRisk
}

protocol AgentTool: Sendable {
    var spec: ToolSpec { get }
    /// A one-line, human-readable description of this specific call, for the approval card.
    func describe(_ args: [String: JSONValue]) -> String
    /// For file edits: what the file would become, so the approval card can show a diff.
    func preview(_ args: [String: JSONValue], context: ToolContext) -> FileChange?
    func run(_ args: [String: JSONValue], context: ToolContext) async throws -> ToolOutput
}

extension AgentTool {
    func preview(_ args: [String: JSONValue], context: ToolContext) -> FileChange? { nil }
    func describe(_ args: [String: JSONValue]) -> String {
        args.map { "\($0.key): \($0.value.compactString.prefix(80))" }.sorted().joined(separator: ", ")
    }
}

struct ToolError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct ParsedToolCall: Sendable { let name: String; let arguments: [String: JSONValue]; let raw: String }

/// Tools are invoked with a fenced ```tool block of JSON, so every model (Apple, MLX, remote)
/// can use them the same way regardless of native function-calling support.
enum ToolProtocol {
    static func manual(for tools: [ToolSpec]) -> String {
        guard !tools.isEmpty else { return "" }
        var lines = [
            "You can use tools to work on the user's project. To call a tool, reply with ONE fenced block and nothing after it:",
            "```tool",
            "{\"name\": \"read_file\", \"arguments\": {\"path\": \"README.md\"}}",
            "```",
            "You will receive the result, then continue. Call at most one tool per reply. Read files before editing them. When you are done, answer normally without a tool block.",
            "Tools:",
        ]
        lines += tools.map { "- \($0.name)(\($0.parameters)): \($0.summary)" }
        return lines.joined(separator: "\n")
    }

    static func parse(_ text: String) -> ParsedToolCall? {
        let pattern = #"```(?:tool|json)?\s*\n(\{[\s\S]*?\})\s*\n```"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let r = Range(match.range(at: 1), in: text), let json = JSONValue.parse(String(text[r])),
                  let name = json["name"]?.string else { continue }
            return ParsedToolCall(name: name, arguments: json["arguments"]?.object ?? [:], raw: String(text[r]))
        }
        return nil
    }

    /// Hides the machine-readable block from the visible reply.
    static func stripCall(from text: String) -> String {
        let pattern = #"```tool[\s\S]*?(```|$)"#
        return text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
