import Foundation

struct FetchURLTool: AgentTool {
    let spec = ToolSpec(name: "fetch_url", summary: "Make an HTTP(S) request and return the response text. GET by default.",
                        parameters: "url: string, method?: string, headers?: object, body?: string", risk: .network)

    func describe(_ args: [String: JSONValue]) -> String {
        var text = "\((args["method"]?.string ?? "GET").uppercased()) \(args["url"]?.string ?? "?")"
        if let headers = args["headers"]?.object, !headers.isEmpty { text += "\nHeaders: " + headers.keys.sorted().joined(separator: ", ") }
        if let body = args["body"]?.string, !body.isEmpty { text += "\nBody: " + body.prefix(400) }
        return text
    }

    static func risk(for args: [String: JSONValue]) -> ToolRisk {
        (args["method"]?.string ?? "GET").uppercased() == "GET" ? .network : .networkWrite
    }

    func run(_ args: [String: JSONValue], context: ToolContext) async throws -> ToolOutput {
        guard context.networkMode != .off else { throw ToolError("Network access is off for this session.") }
        guard let raw = args["url"]?.string, let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased()) else {
            throw ToolError("url must be an http(s) URL")
        }
        guard NetworkPolicy.allows(url, mode: context.networkMode, allowedHosts: context.allowedHosts) else {
            throw ToolError("\(url.host ?? "That site") isn't on this session's allowed sites. Add it in the details panel.")
        }
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.httpMethod = (args["method"]?.string ?? "GET").uppercased()
        for (key, value) in args["headers"]?.object ?? [:] { if let v = value.string { request.setValue(v, forHTTPHeaderField: key) } }
        if let body = args["body"]?.string { request.httpBody = Data(body.utf8) }
        let (data, response) = try await AppNet.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        var text = String(decoding: data.prefix(400_000), as: UTF8.self)
        if (response.mimeType ?? "").contains("html") {
            text = text.replacingOccurrences(of: #"<(script|style)[\s\S]*?</\1>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"\s{2,}"#, with: "\n", options: .regularExpression)
        }
        return ToolOutput(text: "HTTP \(status)\n" + String(text.prefix(16_000)))
    }
}
