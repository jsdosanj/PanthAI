import Foundation
import Observation
import SwiftData

/// Keeps one client per connected server and the tools each one offers.
@MainActor @Observable
final class MCPHub {
    static let shared = MCPHub()

    enum Status: Equatable { case idle, connecting, ready(Int), needsSignIn, failed(String) }
    private(set) var status: [UUID: Status] = [:]
    private(set) var tools: [UUID: [MCPTool]] = [:]
    private(set) var traffic: [UUID: [MCPLogEntry]] = [:]
    private var clients: [UUID: MCPClient] = [:]

    func append(_ entry: MCPLogEntry) {
        var list = traffic[entry.serverID] ?? []
        list.append(entry)
        if list.count > 200 { list.removeFirst(list.count - 200) }
        traffic[entry.serverID] = list
    }

    /// Calls a tool by hand from the inspector. Always goes through the same client the assistant uses.
    func callManually(_ record: MCPServerRecord, tool: String, arguments: [String: JSONValue]) async -> String {
        guard let server = snapshot(record) else { return "Servers must use https." }
        do { return try await client(for: server).callTool(tool, arguments: arguments) }
        catch { return "Error: \(error.localizedDescription)" }
    }
    private var resourceMetadata: [UUID: URL] = [:]

    func snapshot(_ record: MCPServerRecord) -> MCPServerSnapshot? {
        guard let url = URL(string: record.url), url.scheme == "https" else { return nil }
        return MCPServerSnapshot(id: record.id, name: record.name, url: url, readOnly: record.readOnly,
                                 tokenAccount: record.tokenAccount, oauthAccount: record.oauthAccount)
    }

    private func client(for server: MCPServerSnapshot) -> MCPClient {
        if let existing = clients[server.id] { return existing }
        let client = MCPClient(url: server.url, serverID: server.id, onLog: { entry in Task { @MainActor in MCPHub.shared.append(entry) } }) {
            try await MCPOAuth.accessToken(for: server)
        }
        clients[server.id] = client
        return client
    }

    func connect(_ record: MCPServerRecord) async {
        guard let server = snapshot(record) else { status[record.id] = .failed("Servers must use https."); return }
        status[server.id] = .connecting
        do {
            let list = try await client(for: server).listTools()
            tools[server.id] = list
            status[server.id] = .ready(list.count)
        } catch MCPError.needsAuth(let metadata) {
            resourceMetadata[server.id] = metadata
            status[server.id] = .needsSignIn
        } catch {
            status[server.id] = .failed(error.localizedDescription)
        }
    }

    func signIn(_ record: MCPServerRecord) async {
        guard let server = snapshot(record) else { return }
        do {
            try await MCPOAuth.signIn(serverURL: server.url, resourceMetadata: resourceMetadata[server.id],
                                      tokenAccount: server.tokenAccount, oauthAccount: server.oauthAccount)
            clients[server.id] = nil
            await connect(record)
        } catch {
            status[server.id] = .failed(error.localizedDescription)
        }
    }

    func forget(_ id: UUID) { clients[id] = nil; tools[id] = nil; status[id] = nil }

    /// The tools to offer a chat, from the connectors it has switched on.
    func adapters(for records: [MCPServerRecord], limit: Int) async -> [any AgentTool] {
        var result: [any AgentTool] = []
        for record in records {
            if tools[record.id] == nil { await connect(record) }
            guard let server = snapshot(record), let list = tools[record.id] else { continue }
            let usable = record.readOnly ? list.filter(\.readOnly) : list
            for tool in usable.prefix(limit) {
                result.append(MCPToolAdapter(server: server, tool: tool, client: client(for: server)))
            }
        }
        return result
    }
}

/// An MCP tool presented like any built-in tool. Every call asks for approval unless the user allows it for the session.
struct MCPToolAdapter: AgentTool {
    let server: MCPServerSnapshot
    let tool: MCPTool
    let client: MCPClient

    private var safeServerName: String { server.name.lowercased().filter { $0.isLetter || $0.isNumber } }
    var spec: ToolSpec {
        ToolSpec(name: "mcp_\(safeServerName)_\(tool.name)", summary: "[\(server.name)] \(tool.summary)", parameters: tool.parameterList, risk: .remote)
    }
    func describe(_ args: [String: JSONValue]) -> String {
        "\(server.name): \(tool.name)(" + args.map { "\($0.key): \($0.value.compactString.prefix(60))" }.sorted().joined(separator: ", ") + ")"
    }
    func run(_ args: [String: JSONValue], context: ToolContext) async throws -> ToolOutput {
        ToolOutput(text: try await client.callTool(tool.name, arguments: args))
    }
}
