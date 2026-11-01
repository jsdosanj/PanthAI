import Foundation

struct MCPTool: Sendable, Identifiable {
    var id: String { name }
    let name: String
    let summary: String
    let schema: JSONValue
    let readOnly: Bool

    /// "path: string, limit?: number" — compact enough to fit in a prompt.
    var parameterList: String {
        let required = Set((schema["required"]?.array ?? []).compactMap(\.string))
        let props = schema["properties"]?.object ?? [:]
        return props.keys.sorted().prefix(8).map { rawKey in
            let key = rawKey.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
            let type = props[key]?["type"]?.string ?? "any"
            return "\(key)\(required.contains(key) ? "" : "?"): \(type)"
        }.joined(separator: ", ")
    }
}

enum MCPError: LocalizedError {
    case needsAuth(resourceMetadata: URL?)
    case server(String)
    var errorDescription: String? {
        switch self {
        case .needsAuth: "This connector needs you to sign in."
        case .server(let message): message
        }
    }
}

struct MCPLogEntry: Identifiable, Sendable {
    let id = UUID()
    let serverID: UUID
    let date: Date
    let outgoing: Bool
    let summary: String
    let body: String
}

/// A minimal MCP client for the Streamable HTTP transport (JSON or event-stream responses).
actor MCPClient {
    private let url: URL
    private let auth: @Sendable () async throws -> String?
    private let serverID: UUID
    private let onLog: @Sendable (MCPLogEntry) -> Void
    private var sessionID: String?
    private var initialized = false
    private var nextID = 1

    init(url: URL, serverID: UUID, onLog: @escaping @Sendable (MCPLogEntry) -> Void = { _ in }, auth: @escaping @Sendable () async throws -> String?) {
        self.url = url
        self.serverID = serverID
        self.onLog = onLog
        self.auth = auth
    }

    /// Sends one JSON-RPC message and records both directions for the traffic inspector.
    private func post(_ message: [String: JSONValue], expectResponse: Bool = true) async throws -> JSONValue? {
        let method = message["method"]?.string ?? "?"
        onLog(MCPLogEntry(serverID: serverID, date: .now, outgoing: true, summary: method, body: JSONValue.object(message).compactString))
        do {
            let reply = try await rawPost(message, expectResponse: expectResponse)
            if let reply { onLog(MCPLogEntry(serverID: serverID, date: .now, outgoing: false, summary: reply["error"] == nil ? "result" : "error", body: reply.compactString)) }
            return reply
        } catch {
            onLog(MCPLogEntry(serverID: serverID, date: .now, outgoing: false, summary: "failed", body: error.localizedDescription))
            throw error
        }
    }

    private func rawPost(_ message: [String: JSONValue], expectResponse: Bool = true) async throws -> JSONValue? {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if let token = try await auth() { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(JSONValue.object(message))

        let (bytes, response) = try await AppNet.session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw MCPError.server("No response from the server.") }
        if http.statusCode == 401 {
            let header = http.value(forHTTPHeaderField: "WWW-Authenticate") ?? ""
            let metadata = header.range(of: #"resource_metadata="([^"]+)""#, options: .regularExpression)
                .map { String(header[$0]).replacingOccurrences(of: "resource_metadata=", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
                .flatMap(URL.init)
            throw MCPError.needsAuth(resourceMetadata: metadata)
        }
        if let id = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = id }
        guard (200..<300).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines { body += line; if body.count > 400 { break } }
            if http.statusCode == 404 { sessionID = nil; initialized = false }
            throw MCPError.server("Server returned \(http.statusCode). \(body.prefix(200))")
        }
        guard expectResponse else { return nil }

        let wantedID = message["id"]
        var plain = ""
        let isStream = (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("event-stream")
        for try await line in bytes.lines {
            if isStream {
                guard line.hasPrefix("data:") else { continue }
                if let json = JSONValue.parse(line.dropFirst(5).trimmingCharacters(in: .whitespaces)), json["id"] == wantedID { return json }
            } else { plain += line + "\n" }
        }
        return JSONValue.parse(plain)
    }

    private func request(_ method: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        let id = nextID; nextID += 1
        let reply = try await post(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": .object(params)])
        if let error = reply?["error"] { throw MCPError.server(error["message"]?.string ?? "The server reported an error.") }
        return reply?["result"] ?? .null
    }

    private func ensureInitialized() async throws {
        guard !initialized else { return }
        _ = try await request("initialize", [
            "protocolVersion": .string("2025-03-26"), "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("PanthAI"), "version": .string("0.1")]),
        ])
        _ = try await post(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")], expectResponse: false)
        initialized = true
    }

    func listTools() async throws -> [MCPTool] {
        try await ensureInitialized()
        var tools: [MCPTool] = []
        var cursor: String?
        repeat {
            let result = try await request("tools/list", cursor.map { ["cursor": .string($0)] } ?? [:])
            for item in result["tools"]?.array ?? [] {
                guard let name = item["name"]?.string, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }) else { continue }
                tools.append(MCPTool(name: name, summary: Self.cleanDescription(item["description"]?.string ?? ""),
                                     schema: item["inputSchema"] ?? .object([:]),
                                     readOnly: item["annotations"]?["readOnlyHint"]?.bool ?? false))
            }
            cursor = result["nextCursor"]?.string
        } while cursor != nil && tools.count < 200
        return tools
    }

    /// Tool descriptions come from the server and are pasted into the prompt, so strip anything that could pose as a new instruction block.
    private static func cleanDescription(_ text: String) -> String {
        String(text.replacingOccurrences(of: "`", with: "'").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).prefix(140))
    }

    func callTool(_ name: String, arguments: [String: JSONValue]) async throws -> String {
        try await ensureInitialized()
        let result = try await request("tools/call", ["name": .string(name), "arguments": .object(arguments)])
        let text = (result["content"]?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n")
        if result["isError"]?.bool == true { throw MCPError.server(text.isEmpty ? "The tool reported an error." : text) }
        return String((text.isEmpty ? result.compactString : text).prefix(16_000))
    }
}
