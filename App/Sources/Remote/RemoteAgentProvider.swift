import Foundation

enum RemoteAgentKind: String, CaseIterable, Sendable {
    case claude, codex
    var title: String { self == .claude ? "Claude Code" : "Codex" }
}

/// Runs Claude Code or Codex on the user's own machine over SSH and streams what they print.
/// The agent keeps its own tools and files; DosanjhAI just sends the prompt and shows the output.
final class RemoteAgentProvider: ModelProvider, @unchecked Sendable {
    let host: SSHHostSnapshot
    let kind: RemoteAgentKind
    var displayName: String { "\(kind.title) on \(host.name)" }
    private let lock = NSLock()
    private var sessionID: String?

    init(host: SSHHostSnapshot, kind: RemoteAgentKind) {
        self.host = host
        self.kind = kind
    }

    func stream(prompt: String, history: [ChatTurn], kind sessionKind: SessionKind, extraInstructions: String, sampling: SamplingSettings) -> AsyncThrowingStream<String, Error> {
        let session = lock.withLock { sessionID }
        let command: String
        switch kind {
        case .claude:
            // Without a person at the keyboard to approve, Claude runs read-only unless this machine allows edits.
            let mode = host.allowRemoteEdits ? "acceptEdits" : "plan"
            command = "claude -p \(SSHService.quote(prompt)) --output-format stream-json --verbose --permission-mode \(mode)" + (session.map { " --resume \($0)" } ?? "")
        case .codex:
            command = "codex exec --skip-git-repo-check \(host.allowRemoteEdits ? "--full-auto " : "")\(SSHService.quote(prompt))"
        }
        let host = host, kind = kind
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var display = ""
                    var pending = ""
                    for try await chunk in SSHService.stream(host, command: command) {
                        if kind == .codex { display += chunk; continuation.yield(display); continue }
                        pending += chunk
                        while let newline = pending.firstIndex(of: "\n") {
                            let line = String(pending[..<newline]); pending = String(pending[pending.index(after: newline)...])
                            if let update = self.parseClaudeLine(line) { display += update; continuation.yield(display) }
                        }
                    }
                    if kind == .claude, let update = self.parseClaudeLine(pending) { display += update; continuation.yield(display) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Turns one line of `claude --output-format stream-json` into text to show.
    private func parseClaudeLine(_ line: String) -> String? {
        guard let json = JSONValue.parse(line) else { return line.isEmpty ? nil : line + "\n" }
        if let id = json["session_id"]?.string { lock.withLock { sessionID = id } }
        switch json["type"]?.string {
        case "assistant":
            var out = ""
            for block in json["message"]?["content"]?.array ?? [] {
                if let text = block["text"]?.string { out += text + "\n" }
                if block["type"]?.string == "tool_use", let name = block["name"]?.string {
                    let input = block["input"]?.object ?? [:]
                    let detail = input["file_path"]?.string ?? input["command"]?.string ?? input["pattern"]?.string ?? ""
                    out += "\n`\(name)` \(detail.prefix(100))\n\n"
                }
            }
            return out.isEmpty ? nil : out
        case "result":
            if json["is_error"]?.bool == true { return "\n**Error:** \(json["result"]?.string ?? "")\n" }
            return nil
        default: return nil
        }
    }
}
