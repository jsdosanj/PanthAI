import Foundation

enum ToolRegistry {
    static let builtIn: [any AgentTool] = [
        ListFilesTool(), ReadFileTool(), SearchFilesTool(), WriteFileTool(), EditFileTool(),
        FetchURLTool(), WebSearchTool(), RunJavaScriptTool(), CreateFileTool(), RememberTool(),
        GitStatusTool(), GitBranchTool(), GitCommitPushTool(), OpenPullRequestTool(), ListIssuesTool(), CreateIssueTool(), CommentIssueTool(),
        SSHRunTool(), SFTPListTool(), SFTPReadTool(), ListPullRequestsTool(), GetPullRequestTool(), ReviewPullRequestTool(), ListWorkflowRunsTool(), GetFailedJobLogsTool(),
        SearchKnowledgeTool(),
    ]

    static func tools(kind: SessionKind, hasWorkspace: Bool, networkMode: NetworkMode, hasSSH: Bool = false) -> [any AgentTool] {
        let webSearchOn = UserDefaults.standard.object(forKey: Prefs.webSearch) as? Bool ?? true
        let codeExecutionOn = UserDefaults.standard.object(forKey: Prefs.codeExecution) as? Bool ?? true
        let memoryOn = UserDefaults.standard.object(forKey: Prefs.memory) as? Bool ?? true
        return builtIn.filter { tool in
            switch tool.spec.name {
            case "list_files", "read_file", "search_files", "write_file", "edit_file",
                 "git_status", "git_branch", "git_commit_push", "open_pull_request", "list_issues", "create_issue", "comment_issue",
                 "list_pull_requests", "get_pull_request", "review_pull_request", "list_workflow_runs", "get_failed_job_logs": hasWorkspace
            case "ssh_run", "sftp_list", "sftp_read": hasSSH
            case "fetch_url": networkMode != .off
            case "web_search": networkMode != .off && webSearchOn
            case "run_javascript": codeExecutionOn
            case "remember": memoryOn
            case "search_knowledge": KnowledgeData.enabled && KnowledgeData.hasSources
            default: true
            }
        }
    }
}
