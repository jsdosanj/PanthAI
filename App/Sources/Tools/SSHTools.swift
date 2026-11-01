import Foundation

struct SSHRunTool: AgentTool {
    let spec = ToolSpec(name: "ssh_run", summary: "Run a shell command on the connected machine and return its output. Destructive commands are refused.", parameters: "command: string", risk: .remote)
    func describe(_ args: [String: JSONValue]) -> String { "On remote machine: \(args["command"]?.string ?? "")" }
    func run(_ args: [String: JSONValue], context: ToolContext) async throws -> ToolOutput {
        guard let host = context.sshHost else { throw ToolError("No remote machine is selected for this chat.") }
        guard let command = args["command"]?.string, !command.isEmpty else { throw ToolError("command is required") }
        if let problem = RemoteCommandGuard.problem(with: command) { throw ToolError(problem) }
        return ToolOutput(text: try await SSHService.run(host, command: command))
    }
}

struct SFTPListTool: AgentTool {
    let spec = ToolSpec(name: "sftp_list", summary: "List a folder on the connected machine.", parameters: "path: string", risk: .network)
    func run(_ args: [String: JSONValue], context: ToolContext) async throws -> ToolOutput {
        guard let host = context.sshHost else { throw ToolError("No remote machine is selected for this chat.") }
        let (path, items) = try await SSHService.list(host, path: args["path"]?.string ?? ".")
        return ToolOutput(text: "\(path)\n" + items.prefix(200).map { ($0.isDirectory ? "[dir]  " : "[file] ") + $0.name }.joined(separator: "\n"))
    }
}

struct SFTPReadTool: AgentTool {
    let spec = ToolSpec(name: "sftp_read", summary: "Read a text file on the connected machine.", parameters: "path: string", risk: .network)
    func run(_ args: [String: JSONValue], context: ToolContext) async throws -> ToolOutput {
        guard let host = context.sshHost, let path = args["path"]?.string else { throw ToolError("A connected machine and path are required.") }
        let data = try await SSHService.read(host, path: path, limit: 60_000)
        guard let text = String(data: data, encoding: .utf8) else { throw ToolError("That file isn't text.") }
        return ToolOutput(text: String(text.prefix(14_000)))
    }
}
