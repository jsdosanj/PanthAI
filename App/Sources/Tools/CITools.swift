import Foundation

struct ListPullRequestsTool: AgentTool {
    let spec = ToolSpec(name: "list_pull_requests", summary: "List open pull requests in the attached repo.", parameters: "", risk: .network)
    func run(_ args: [String: JSONValue], context: ToolContext) async throws -> ToolOutput {
        guard let full = context.workspaceFullName else { throw ToolError("No GitHub repo is attached.") }
        let prs = try await GitHubClient().json("/repos/\(full)/pulls?state=open&per_page=30").array ?? []
        let lines = prs.compactMap { pr -> String? in
            guard let n = pr["number"]?.int, let title = pr["title"]?.string else { return nil }
            return "#\(n) \(title) (\(pr["head"]?["ref"]?.string ?? "?") → \(pr["base"]?["ref"]?.string ?? "?"))"
        }
        return ToolOutput(text: lines.isEmpty ? "No open pull requests." : lines.joined(separator: "\n"))
    }
}

struct GetPullRequestTool: AgentTool {
    let spec = ToolSpec(name: "get_pull_request", summary: "Get a pull request's description and its diff.", parameters: "number: number", risk: .network)
    func run(_ args: [String: JSONValue], context: ToolContext) async throws -> ToolOutput {
        guard let full = context.workspaceFullName, let n = args["number"]?.int else { throw ToolError("number is required") }
        let client = GitHubClient()
        let pr = try await client.json("/repos/\(full)/pulls/\(n)")
        let diff = try await client.text("/repos/\(full)/pulls/\(n)", accept: "application/vnd.github.v3.diff")
        let head = "#\(n) \(pr["title"]?.string ?? "")\n\(pr["body"]?.string?.prefix(1500) ?? "")\n\nDiff:\n"
        return ToolOutput(text: head + String(diff.prefix(14_000)) + (diff.count > 14_000 ? "\n… (diff truncated)" : ""))
    }
}

struct ReviewPullRequestTool: AgentTool {
    let spec = ToolSpec(name: "review_pull_request", summary: "Submit a review on a pull request. event is COMMENT, APPROVE or REQUEST_CHANGES.", parameters: "number: number, body: string, event?: string", risk: .remote)
    func describe(_ args: [String: JSONValue]) -> String { "Review #\(args["number"]?.int ?? 0) as \(args["event"]?.string ?? "COMMENT")" }
    func run(_ args: [String: JSONValue], context: ToolContext) async throws -> ToolOutput {
        guard let full = context.workspaceFullName, let n = args["number"]?.int, let body = args["body"]?.string else { throw ToolError("number and body are required") }
        let event = (args["event"]?.string ?? "COMMENT").uppercased()
        guard ["COMMENT", "APPROVE", "REQUEST_CHANGES"].contains(event) else { throw ToolError("event must be COMMENT, APPROVE or REQUEST_CHANGES") }
        let review = try await GitHubClient().send("POST", "/repos/\(full)/pulls/\(n)/reviews", body: ["body": .string(body), "event": .string(event)])
        return ToolOutput(text: "Submitted review: \(review["html_url"]?.string ?? "")")
    }
}

struct ListWorkflowRunsTool: AgentTool {
    let spec = ToolSpec(name: "list_workflow_runs", summary: "List recent GitHub Actions runs (failed ones by default).", parameters: "status?: string, branch?: string", risk: .network)
    func run(_ args: [String: JSONValue], context: ToolContext) async throws -> ToolOutput {
        guard let full = context.workspaceFullName else { throw ToolError("No GitHub repo is attached.") }
        var path = "/repos/\(full)/actions/runs?per_page=10&status=\(args["status"]?.string ?? "failure")"
        if let branch = args["branch"]?.string { path += "&branch=\(branch)" }
        let runs = try await GitHubClient().json(path)["workflow_runs"]?.array ?? []
        let lines = runs.compactMap { run -> String? in
            guard let id = run["id"]?.int else { return nil }
            return "run \(id): \(run["name"]?.string ?? "") on \(run["head_branch"]?.string ?? "?") — \(run["conclusion"]?.string ?? run["status"]?.string ?? "")"
        }
        return ToolOutput(text: lines.isEmpty ? "No matching runs." : lines.joined(separator: "\n"))
    }
}

struct GetFailedJobLogsTool: AgentTool {
    let spec = ToolSpec(name: "get_failed_job_logs", summary: "Get the end of the logs for the failed jobs in a workflow run.", parameters: "run_id: number", risk: .network)
    func run(_ args: [String: JSONValue], context: ToolContext) async throws -> ToolOutput {
        guard let full = context.workspaceFullName, let runID = args["run_id"]?.int else { throw ToolError("run_id is required") }
        let client = GitHubClient()
        let jobs = try await client.json("/repos/\(full)/actions/runs/\(runID)/jobs")["jobs"]?.array ?? []
        let failed = jobs.filter { $0["conclusion"]?.string == "failure" }.prefix(2)
        guard !failed.isEmpty else { return ToolOutput(text: "No failed jobs in that run.") }
        var out = ""
        for job in failed {
            guard let id = job["id"]?.int else { continue }
            let log = (try? await client.text("/repos/\(full)/actions/jobs/\(id)/logs")) ?? "(couldn't download this log)"
            out += "=== \(job["name"]?.string ?? "job") ===\n" + String(log.suffix(5_000)) + "\n"
        }
        return ToolOutput(text: out)
    }
}
