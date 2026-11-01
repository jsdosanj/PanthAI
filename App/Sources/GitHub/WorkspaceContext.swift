import Foundation

/// Builds the project context sent to the model with each code-session prompt:
/// the file list, plus the contents of pinned files and any `@path` mentioned in the prompt.
enum WorkspaceContext {
    static func block(_ workspace: WorkspaceRecord, pinned: [String], prompt: String, budget: Int) -> String {
        let paths = WorkspaceFiles.paths(in: workspace)
        var lines = ["Project: \(workspace.displayName)"]
        // Repo instruction files (AGENTS.md, CLAUDE.md, Copilot and Cursor rules) steer the assistant like a teammate's README.
        let instructionFiles = ["AGENTS.md", "CLAUDE.md", ".github/copilot-instructions.md", ".cursorrules"]
        var instructionBudget = 4_000
        for name in instructionFiles where instructionBudget > 0 {
            guard let text = WorkspaceFiles.read(name, in: workspace), !text.isEmpty else { continue }
            let clipped = String(text.prefix(instructionBudget))
            instructionBudget -= clipped.count
            lines += ["", "Project instructions (\(name)):", clipped]
        }
        lines += ["", "Files (\(paths.count)):"]
        lines += paths.prefix(150).map { "  \($0)" }
        if paths.count > 150 { lines.append("  … and \(paths.count - 150) more") }

        let mentioned = mentions(in: prompt, among: paths)
        var remaining = budget
        for path in (pinned + mentioned).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } } {
            guard remaining > 500, var text = WorkspaceFiles.read(path, in: workspace) else { continue }
            if text.count > 8_000 { text = String(text.prefix(8_000)) + "\n… (truncated)" }
            text = String(text.prefix(remaining))
            remaining -= text.count
            lines += ["", "--- \(path) ---", text]
        }
        return lines.joined(separator: "\n")
    }

    static func mentions(in prompt: String, among paths: [String]) -> [String] {
        let tokens = prompt.split(whereSeparator: { $0.isWhitespace }).filter { $0.hasPrefix("@") }.map { String($0.dropFirst()) }
        return tokens.compactMap { token in paths.first { $0 == token || $0.hasSuffix("/" + token) } }
    }
}
