import Foundation

/// Resolves a model-supplied path inside the workspace. Rejects anything that could escape it.
enum WorkspacePath {
    static func resolve(_ path: String, root: URL?) throws -> URL {
        guard let root else { throw ToolError("No GitHub repo is attached to this session. Use /repo first.") }
        let clean = path.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, !clean.hasPrefix("/"), !clean.split(separator: "/").contains("..") else {
            throw ToolError("Path must be relative to the repo root and stay inside it: \(path)")
        }
        let parts = clean.split(separator: "/").map(String.init)
        guard !parts.contains("."), parts.first?.lowercased() != ".dosanjhai" else { throw ToolError("That path is reserved.") }
        let url = root.appending(path: clean)
        guard url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path) else { throw ToolError("Path escapes the repo.") }
        return url
    }
}

struct ListFilesTool: AgentTool {
    let spec = ToolSpec(name: "list_files", summary: "List files in the repo, optionally under a folder.", parameters: "folder?: string", risk: .read)
    func run(_ args: [String: JSONValue], context: ToolContext) async throws -> ToolOutput {
        guard let root = context.workspaceRoot else { throw ToolError("No repo attached.") }
        let prefix = args["folder"]?.string?.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) ?? ""
        let paths = WorkspaceFiles.paths(at: root).filter { prefix.isEmpty || $0.hasPrefix(prefix + "/") }
        return ToolOutput(text: paths.isEmpty ? "No files." : paths.prefix(300).joined(separator: "\n") + (paths.count > 300 ? "\n… \(paths.count - 300) more" : ""))
    }
}

struct ReadFileTool: AgentTool {
    let spec = ToolSpec(name: "read_file", summary: "Read a text file (with line numbers).", parameters: "path: string, start_line?: number, end_line?: number", risk: .read)
    func run(_ args: [String: JSONValue], context: ToolContext) async throws -> ToolOutput {
        let url = try WorkspacePath.resolve(args["path"]?.string ?? "", root: context.workspaceRoot)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw ToolError("Can't read that file (missing or not text).") }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let start = max((args["start_line"]?.int ?? 1), 1)
        let end = min(args["end_line"]?.int ?? (start + 399), lines.count)
        guard start <= end else { return ToolOutput(text: "(empty range; file has \(lines.count) lines)") }
        let body = lines[(start - 1)..<end].enumerated().map { "\(start + $0.offset)\t\($0.element)" }.joined(separator: "\n")
        return ToolOutput(text: String(body.prefix(12_000)) + (end < lines.count ? "\n… (file has \(lines.count) lines)" : ""))
    }
}

struct SearchFilesTool: AgentTool {
    let spec = ToolSpec(name: "search_files", summary: "Find lines containing text across the repo.", parameters: "query: string", risk: .read)
    func run(_ args: [String: JSONValue], context: ToolContext) async throws -> ToolOutput {
        guard let root = context.workspaceRoot, let query = args["query"]?.string, !query.isEmpty else { throw ToolError("query is required") }
        var hits: [String] = []
        for path in WorkspaceFiles.paths(at: root) {
            guard let text = try? String(contentsOf: root.appending(path: path), encoding: .utf8) else { continue }
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where line.localizedCaseInsensitiveContains(query) {
                hits.append("\(path):\(index + 1): \(line.trimmingCharacters(in: .whitespaces).prefix(160))")
                if hits.count >= 60 { return ToolOutput(text: hits.joined(separator: "\n") + "\n… (more matches)") }
            }
        }
        return ToolOutput(text: hits.isEmpty ? "No matches." : hits.joined(separator: "\n"))
    }
}

struct WriteFileTool: AgentTool {
    let spec = ToolSpec(name: "write_file", summary: "Create or overwrite a file with the full new content.", parameters: "path: string, content: string", risk: .write)
    func describe(_ args: [String: JSONValue]) -> String { "Write \(args["path"]?.string ?? "?")" }

    func preview(_ args: [String: JSONValue], context: ToolContext) -> FileChange? {
        guard let path = args["path"]?.string, let content = args["content"]?.string,
              let url = try? WorkspacePath.resolve(path, root: context.workspaceRoot) else { return nil }
        return FileChange(path: path, before: try? String(contentsOf: url, encoding: .utf8), after: content)
    }

    func run(_ args: [String: JSONValue], context: ToolContext) async throws -> ToolOutput {
        guard let change = preview(args, context: context) else { throw ToolError("path and content are required") }
        guard change.after.utf8.count <= 500_000 else { throw ToolError("File too large (500 KB limit).") }
        let url = try WorkspacePath.resolve(change.path, root: context.workspaceRoot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try change.after.write(to: url, atomically: true, encoding: .utf8)
        return ToolOutput(text: "Wrote \(change.path) (\(change.after.split(separator: "\n").count) lines).", change: change)
    }
}

struct EditFileTool: AgentTool {
    let spec = ToolSpec(name: "edit_file", summary: "Replace one exact piece of text in a file. old_text must match exactly once.", parameters: "path: string, old_text: string, new_text: string", risk: .write)
    func describe(_ args: [String: JSONValue]) -> String { "Edit \(args["path"]?.string ?? "?")" }

    func preview(_ args: [String: JSONValue], context: ToolContext) -> FileChange? {
        guard let path = args["path"]?.string, let old = args["old_text"]?.string, let new = args["new_text"]?.string,
              let url = try? WorkspacePath.resolve(path, root: context.workspaceRoot),
              let current = try? String(contentsOf: url, encoding: .utf8),
              current.components(separatedBy: old).count == 2 else { return nil }
        return FileChange(path: path, before: current, after: current.replacingOccurrences(of: old, with: new))
    }

    func run(_ args: [String: JSONValue], context: ToolContext) async throws -> ToolOutput {
        guard let change = preview(args, context: context) else {
            throw ToolError("old_text must appear exactly once in the file. Read the file again and copy the text exactly.")
        }
        let url = try WorkspacePath.resolve(change.path, root: context.workspaceRoot)
        try change.after.write(to: url, atomically: true, encoding: .utf8)
        return ToolOutput(text: "Edited \(change.path).", change: change)
    }
}
