import CryptoKit
import Foundation

/// Git-style workflow over the GitHub API: no local .git, no libgit2. Changes are compared with the
/// snapshot taken when the repo was loaded, then committed with the Git Data API.
enum GitWorkspace {
    static func blobSHA(_ data: Data) -> String {
        var input = Data("blob \(data.count)\0".utf8)
        input.append(data)
        return Insecure.SHA1.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }

    struct Change { let path: String; let isNew: Bool; let data: Data }

    static func manifest(_ context: ToolContext) throws -> (root: URL, manifest: WorkspaceImporter.Manifest) {
        guard let root = context.workspaceRoot else { throw ToolError("No GitHub repo is attached. Use /repo first.") }
        guard let manifest = WorkspaceImporter.loadManifest(root) else { throw ToolError("This repo was loaded without git info. Detach it and load it again.") }
        return (root, manifest)
    }

    static func changes(root: URL, manifest: WorkspaceImporter.Manifest) -> [Change] {
        WorkspaceFiles.paths(at: root).compactMap { path in
            guard let data = try? Data(contentsOf: root.appending(path: path)) else { return nil }
            let sha = blobSHA(data)
            guard manifest.shas[path] != sha else { return nil }
            return Change(path: path, isNew: manifest.shas[path] == nil, data: data)
        }
    }
}

struct GitStatusTool: AgentTool {
    let spec = ToolSpec(name: "git_status", summary: "Show which files you changed or added since the repo was loaded or last committed.", parameters: "", risk: .read)
    func run(_ args: [String: JSONValue], context: ToolContext) async throws -> ToolOutput {
        let (root, manifest) = try GitWorkspace.manifest(context)
        let changes = GitWorkspace.changes(root: root, manifest: manifest)
        let header = "On branch \(manifest.branch) (based on \(manifest.baseBranch))"
        return ToolOutput(text: changes.isEmpty ? header + "\nNothing to commit." : header + "\n" + changes.map { "\($0.isNew ? "added   " : "modified") \($0.path)" }.joined(separator: "\n"))
    }
}

struct GitBranchTool: AgentTool {
    let spec = ToolSpec(name: "git_branch", summary: "Create a new branch on GitHub from the current commit and switch to it.", parameters: "name: string", risk: .remote)
    func describe(_ args: [String: JSONValue]) -> String { "Create branch \(args["name"]?.string ?? "?") on GitHub" }
    func run(_ args: [String: JSONValue], context: ToolContext) async throws -> ToolOutput {
        let (root, manifest) = try GitWorkspace.manifest(context)
        guard let name = args["name"]?.string?.trimmingCharacters(in: .whitespaces), !name.isEmpty, !name.contains(" "), !name.contains("..") else {
            throw ToolError("Give a branch name without spaces, like feature/login-fix")
        }
        _ = try await GitHubClient().send("POST", "/repos/\(manifest.fullName)/git/refs", body: ["ref": .string("refs/heads/\(name)"), "sha": .string(manifest.headCommit)])
        var updated = manifest
        updated.branch = name
        try WorkspaceImporter.saveManifest(updated, root: root)
        return ToolOutput(text: "Created and switched to branch \(name).")
    }
}

struct GitCommitPushTool: AgentTool {
    let spec = ToolSpec(name: "git_commit_push", summary: "Commit all changed files to the current branch on GitHub. Refuses the repo's default branch; make a branch first.", parameters: "message: string", risk: .remote)
    func describe(_ args: [String: JSONValue]) -> String { "Commit and push: \(args["message"]?.string ?? "")" }

    func run(_ args: [String: JSONValue], context: ToolContext) async throws -> ToolOutput {
        let (root, manifest) = try GitWorkspace.manifest(context)
        guard let message = args["message"]?.string, !message.isEmpty else { throw ToolError("message is required") }
        let client = GitHubClient()
        let repo = try await client.repo(manifest.fullName)
        guard manifest.branch != repo.defaultBranch else {
            throw ToolError("This is the default branch (\(repo.defaultBranch)). Create a branch with git_branch, commit there, then open a pull request.")
        }
        let changes = GitWorkspace.changes(root: root, manifest: manifest)
        guard !changes.isEmpty else { return ToolOutput(text: "Nothing to commit.") }

        var entries: [JSONValue] = []
        var newShas = manifest.shas
        var skipped: [String] = []
        var modes = manifest.modes ?? [:]
        for change in changes {
            guard let text = String(data: change.data, encoding: .utf8) else { skipped.append(change.path); continue }
            // Keep a script executable: use the recorded mode, or the file's own executable bit (e.g. a script the assistant made executable).
            let permissions = (try? FileManager.default.attributesOfItem(atPath: root.appending(path: change.path).path)[.posixPermissions] as? Int) ?? 0o644
            let mode = (modes[change.path] == "100755" || permissions & 0o111 != 0) ? "100755" : "100644"
            if mode == "100755" { modes[change.path] = mode }
            let blob = try await client.send("POST", "/repos/\(manifest.fullName)/git/blobs", body: ["content": .string(text), "encoding": .string("utf-8")])
            guard let sha = blob["sha"]?.string else { throw ToolError("GitHub didn't return a blob id.") }
            entries.append(.object(["path": .string(change.path), "mode": .string(mode), "type": .string("blob"), "sha": .string(sha)]))
            newShas[change.path] = sha
        }
        let tree = try await client.send("POST", "/repos/\(manifest.fullName)/git/trees", body: ["base_tree": .string(manifest.headTree), "tree": .array(entries)])
        guard let treeSHA = tree["sha"]?.string else { throw ToolError("GitHub didn't return a tree id.") }
        let commit = try await client.send("POST", "/repos/\(manifest.fullName)/git/commits",
                                           body: ["message": .string(message), "tree": .string(treeSHA), "parents": .array([.string(manifest.headCommit)])])
        guard let commitSHA = commit["sha"]?.string else { throw ToolError("GitHub didn't return a commit id.") }
        let encoded = manifest.branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? manifest.branch
        _ = try await client.send("PATCH", "/repos/\(manifest.fullName)/git/refs/heads/\(encoded)", body: ["sha": .string(commitSHA), "force": .bool(false)])

        var updated = manifest
        updated.headCommit = commitSHA; updated.headTree = treeSHA; updated.shas = newShas; updated.modes = modes
        try WorkspaceImporter.saveManifest(updated, root: root)
        let deleted = manifest.shas.keys.filter { !FileManager.default.fileExists(atPath: root.appending(path: $0).path) }
        var note = "Pushed \(changes.count - skipped.count) file(s) to \(manifest.branch) as \(commitSHA.prefix(7))."
        if !skipped.isEmpty { note += " Not pushed because they aren't text: " + skipped.prefix(5).joined(separator: ", ") + "." }
        if !deleted.isEmpty { note += " Files missing locally were not removed on GitHub: " + deleted.sorted().prefix(5).joined(separator: ", ") + "." }
        return ToolOutput(text: note)
    }
}

struct OpenPullRequestTool: AgentTool {
    let spec = ToolSpec(name: "open_pull_request", summary: "Open a pull request from the current branch into the branch the repo was loaded from.", parameters: "title: string, body?: string", risk: .remote)
    func describe(_ args: [String: JSONValue]) -> String { "Open pull request: \(args["title"]?.string ?? "")" }
    func run(_ args: [String: JSONValue], context: ToolContext) async throws -> ToolOutput {
        let (_, manifest) = try GitWorkspace.manifest(context)
        guard let title = args["title"]?.string, !title.isEmpty else { throw ToolError("title is required") }
        guard manifest.branch != manifest.baseBranch else { throw ToolError("You're on the base branch. Create a branch and commit first.") }
        let pr = try await GitHubClient().send("POST", "/repos/\(manifest.fullName)/pulls",
                                               body: ["title": .string(title), "head": .string(manifest.branch), "base": .string(manifest.baseBranch), "body": .string(args["body"]?.string ?? "")])
        return ToolOutput(text: "Opened pull request: \(pr["html_url"]?.string ?? "")")
    }
}

struct ListIssuesTool: AgentTool {
    let spec = ToolSpec(name: "list_issues", summary: "List open issues in the attached repo.", parameters: "", risk: .network)
    func run(_ args: [String: JSONValue], context: ToolContext) async throws -> ToolOutput {
        guard let full = context.workspaceFullName else { throw ToolError("No GitHub repo is attached.") }
        let issues = try await GitHubClient().json("/repos/\(full)/issues?state=open&per_page=30").array ?? []
        let lines = issues.filter { $0["pull_request"] == nil }.compactMap { issue -> String? in
            guard let number = issue["number"]?.int, let title = issue["title"]?.string else { return nil }
            return "#\(number) \(title)"
        }
        return ToolOutput(text: lines.isEmpty ? "No open issues." : lines.joined(separator: "\n"))
    }
}

struct CreateIssueTool: AgentTool {
    let spec = ToolSpec(name: "create_issue", summary: "Open a new issue in the attached repo.", parameters: "title: string, body?: string", risk: .remote)
    func describe(_ args: [String: JSONValue]) -> String { "Create issue: \(args["title"]?.string ?? "")" }
    func run(_ args: [String: JSONValue], context: ToolContext) async throws -> ToolOutput {
        guard let full = context.workspaceFullName, let title = args["title"]?.string, !title.isEmpty else { throw ToolError("A repo and title are required.") }
        let issue = try await GitHubClient().send("POST", "/repos/\(full)/issues", body: ["title": .string(title), "body": .string(args["body"]?.string ?? "")])
        return ToolOutput(text: "Created issue: \(issue["html_url"]?.string ?? "")")
    }
}

struct CommentIssueTool: AgentTool {
    let spec = ToolSpec(name: "comment_issue", summary: "Comment on an issue or pull request by number.", parameters: "number: number, body: string", risk: .remote)
    func describe(_ args: [String: JSONValue]) -> String { "Comment on #\(args["number"]?.int ?? 0)" }
    func run(_ args: [String: JSONValue], context: ToolContext) async throws -> ToolOutput {
        guard let full = context.workspaceFullName, let number = args["number"]?.int, let body = args["body"]?.string, !body.isEmpty else { throw ToolError("number and body are required.") }
        let comment = try await GitHubClient().send("POST", "/repos/\(full)/issues/\(number)/comments", body: ["body": .string(body)])
        return ToolOutput(text: "Commented: \(comment["html_url"]?.string ?? "")")
    }
}
