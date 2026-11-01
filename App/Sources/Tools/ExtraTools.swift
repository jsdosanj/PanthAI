import Foundation
import WebKit

// MARK: Web search

struct WebSearchTool: AgentTool {
    let spec = ToolSpec(name: "web_search", summary: "Search the web. Returns titles, links and snippets.", parameters: "query: string", risk: .network)
    static let braveKeyAccount = "search.brave"

    func run(_ args: [String: JSONValue], context: ToolContext) async throws -> ToolOutput {
        guard context.networkMode != .off else { throw ToolError("Network access is off for this session.") }
        guard let query = args["query"]?.string, !query.isEmpty else { throw ToolError("query is required") }
        let probe = URL(string: Keychain.get(Self.braveKeyAccount) == nil ? "https://duckduckgo.com" : "https://api.search.brave.com")!
        guard NetworkPolicy.allows(probe, mode: context.networkMode, allowedHosts: context.allowedHosts) else {
            throw ToolError("Web search isn't on this session's allowed sites.")
        }
        let results: [Hit]
        if let key = Keychain.get(Self.braveKeyAccount) { results = try await brave(query, key: key) } else { results = try await duckDuckGo(query) }
        guard !results.isEmpty else { return ToolOutput(text: "No results.") }
        return ToolOutput(text: results.enumerated().map { "\($0.offset + 1). \($0.element.title)\n   \($0.element.url)\n   \($0.element.snippet)" }.joined(separator: "\n"))
    }

    struct Hit { let title: String; let url: String; let snippet: String }

    private func brave(_ query: String, key: String) async throws -> [Hit] {
        var comps = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
        comps.queryItems = [.init(name: "q", value: query), .init(name: "count", value: "8")]
        var request = URLRequest(url: comps.url!, timeoutInterval: 20)
        request.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
        let (data, _) = try await AppNet.session.data(for: request)
        let items = JSONValue.parse(String(decoding: data, as: UTF8.self))?["web"]?["results"]?.array ?? []
        return items.compactMap { item in
            guard let title = item["title"]?.string, let url = item["url"]?.string else { return nil }
            return Hit(title: title, url: url, snippet: Self.plain(item["description"]?.string ?? ""))
        }
    }

    /// DuckDuckGo's no-key HTML endpoint. Best effort: the page layout can change.
    private func duckDuckGo(_ query: String) async throws -> [Hit] {
        var comps = URLComponents(string: "https://html.duckduckgo.com/html/")!
        comps.queryItems = [.init(name: "q", value: query)]
        var request = URLRequest(url: comps.url!, timeoutInterval: 20)
        request.setValue("Mozilla/5.0 (iPad; CPU OS 26_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await AppNet.session.data(for: request)
        let html = String(decoding: data, as: UTF8.self)
        let link = try NSRegularExpression(pattern: #"class="result__a"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>"#)
        let snippet = try NSRegularExpression(pattern: #"class="result__snippet"[^>]*>([\s\S]*?)</a>"#)
        let range = NSRange(html.startIndex..., in: html)
        let snippets = snippet.matches(in: html, range: range).compactMap { Range($0.range(at: 1), in: html).map { Self.plain(String(html[$0])) } }
        var hits: [Hit] = []
        for (i, m) in link.matches(in: html, range: range).enumerated() where hits.count < 8 {
            guard let hrefR = Range(m.range(at: 1), in: html), let titleR = Range(m.range(at: 2), in: html) else { continue }
            var href = String(html[hrefR])
            if let comps = URLComponents(string: href.hasPrefix("//") ? "https:" + href : href),
               let real = comps.queryItems?.first(where: { $0.name == "uddg" })?.value { href = real }
            hits.append(Hit(title: Self.plain(String(html[titleR])), url: href, snippet: i < snippets.count ? snippets[i] : ""))
        }
        return hits
    }

    static func plain(_ html: String) -> String {
        html.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: Code execution (JavaScript, sandboxed)

/// Runs JavaScript in an offscreen web view with network, files and the app all out of reach.
/// A runaway script is abandoned after the timeout (its result is discarded and the view released); iPadOS
/// reclaims the web process, but a tight loop can keep it busy for a while.
@MainActor
enum JSSandbox {
    static func run(_ code: String, timeout: Duration = .seconds(10)) async -> String {
        let configuration = WKWebViewConfiguration()
        let web = WKWebView(frame: .zero, configuration: configuration)
        let guardrail = NoNavigation()
        web.navigationDelegate = guardrail
        defer { withExtendedLifetime(guardrail) {} }
        let rules = #"[{"trigger":{"url-filter":".*","resource-type":["image","style-sheet","script","font","raw","media","svg-document","fetch","websocket","ping","popup"]},"action":{"type":"block"}}]"#
        guard let list = try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "js-sandbox", encodedContentRuleList: rules) else {
            return "The code sandbox couldn't start its network block, so nothing was run."   // fail closed
        }
        configuration.userContentController.add(list)
        let body = """
        const __logs = [];
        const console = { log: (...a) => __logs.push(a.map(String).join(' ')), error: (...a) => __logs.push('error: ' + a.map(String).join(' ')), warn: (...a) => __logs.push('warn: ' + a.map(String).join(' ')) };
        let __result = null;
        try { __result = await (async () => { \(code)\n })(); } catch (e) { __logs.push('Error: ' + e); }
        return JSON.stringify({ logs: __logs, result: __result === undefined || __result === null ? null : String(__result) });
        """
        let race = Race()
        let output: String = await withCheckedContinuation { continuation in
            race.continuation = continuation
            Task { @MainActor in
                let value = try? await web.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
                guard let text = value as? String, let json = JSONValue.parse(text) else { race.finish("The script did not return a result."); return }
                var lines = (json["logs"]?.array ?? []).compactMap(\.string)
                if let result = json["result"]?.string { lines.append("=> " + result) }
                race.finish(String((lines.isEmpty ? "(no output)" : lines.joined(separator: "\n")).prefix(8_000)))
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                race.finish("Stopped: the script ran longer than 10 seconds.")
            }
        }
        web.stopLoading()
        return output
    }

    /// Resolves with whichever of "script finished" or "timed out" happens first.
    @MainActor private final class Race {
        var continuation: CheckedContinuation<String, Never>?
        func finish(_ text: String) {
            continuation?.resume(returning: text)
            continuation = nil
        }
    }
}

struct RunJavaScriptTool: AgentTool {
    let spec = ToolSpec(name: "run_javascript", summary: "Run JavaScript in a sandbox (no network or files) for calculations and data work. Use console.log or return a value.", parameters: "code: string", risk: .execute)
    func describe(_ args: [String: JSONValue]) -> String { String((args["code"]?.string ?? "").prefix(400)) }
    func run(_ args: [String: JSONValue], context: ToolContext) async throws -> ToolOutput {
        guard let code = args["code"]?.string, !code.isEmpty else { throw ToolError("code is required") }
        return ToolOutput(text: await JSSandbox.run(code))
    }
}

// MARK: Files app

enum FilesFolder {
    /// Shown in the Files app under “On My iPad › DosanjhAI” (file sharing is enabled in Info.plist).
    static var root: URL { URL.documentsDirectory }
    /// Files the assistant creates go here, so it can never overwrite your downloads, evals or anything else in the folder.
    static var created: URL { root.appending(path: "Created by DosanjhAI", directoryHint: .isDirectory) }
}

struct CreateFileTool: AgentTool {
    let spec = ToolSpec(name: "create_file", summary: "Create a file the user can open from the Files app (notes, reports, scripts, CSVs). Saved in the DosanjhAI folder.",
                        parameters: "path: string, content: string", risk: .write)
    func describe(_ args: [String: JSONValue]) -> String { "Create \(args["path"]?.string ?? "?") in the Files app" }

    private func resolve(_ path: String) throws -> URL {
        let clean = path.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, !clean.hasPrefix("/"), !clean.split(separator: "/").contains("..") else { throw ToolError("Use a simple relative file name, like notes/summary.md") }
        return FilesFolder.created.appending(path: clean)
    }

    func preview(_ args: [String: JSONValue], context: ToolContext) -> FileChange? {
        guard let path = args["path"]?.string, let content = args["content"]?.string, let url = try? resolve(path) else { return nil }
        return FileChange(scope: "documents", path: path, before: try? String(contentsOf: url, encoding: .utf8), after: content)
    }

    func run(_ args: [String: JSONValue], context: ToolContext) async throws -> ToolOutput {
        guard let change = preview(args, context: context) else { throw ToolError("path and content are required") }
        guard change.after.utf8.count <= 2_000_000 else { throw ToolError("File too large (2 MB limit).") }
        let url = try resolve(change.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try change.after.write(to: url, atomically: true, encoding: .utf8)
        return ToolOutput(text: "Saved \(change.path). Open the Files app → On My iPad → DosanjhAI → Created by DosanjhAI.", change: change)
    }
}

// MARK: Memory

/// Plain-text memory the assistant keeps across chats. Local to the device; the user can read, edit and clear it.
enum MemoryStore {
    private static var folder: URL {
        var url = URL.applicationSupportDirectory.appending(path: "Memory", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = false
        try? url.setResourceValues(values)
        return url
    }
    static func url(for agent: UUID?) -> URL { folder.appending(path: (agent?.uuidString ?? "global") + ".md") }
    static func load(agent: UUID? = nil) -> String { (try? String(contentsOf: url(for: agent), encoding: .utf8)) ?? "" }
    static func save(_ text: String, agent: UUID? = nil) { try? text.write(to: url(for: agent), atomically: true, encoding: .utf8) }
    static func append(_ note: String, agent: UUID? = nil) {
        var text = load(agent: agent)
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        save(text + "- " + note.replacingOccurrences(of: "\n", with: " ") + "\n", agent: agent)
    }
    /// What gets added to the model's instructions.
    static func promptBlock(agent: UUID?) -> String {
        var parts = [load(agent: nil)]
        if agent != nil { parts.append(load(agent: agent)) }
        let text = parts.filter { !$0.isEmpty }.joined(separator: "\n")
        return text.isEmpty ? "" : "Things you remember about the user and their work:\n" + String(text.suffix(2_500))
    }
}

struct RememberTool: AgentTool {
    let spec = ToolSpec(name: "remember", summary: "Save a short fact worth remembering in future chats (preferences, names, project details). Only save what the user would want kept.", parameters: "note: string", risk: .write)
    func describe(_ args: [String: JSONValue]) -> String { "Remember: \(args["note"]?.string ?? "")" }
    func run(_ args: [String: JSONValue], context: ToolContext) async throws -> ToolOutput {
        guard context.memoryEnabled else { throw ToolError("Memory is turned off in Settings.") }
        guard let note = args["note"]?.string, !note.isEmpty, note.count < 400 else { throw ToolError("note must be a short sentence") }
        MemoryStore.append(note, agent: context.memoryAgentID)
        return ToolOutput(text: "Remembered.")
    }
}

/// A script (or HTML) must not be able to send the web view to another address: that would be a way to leak data.
final class NoNavigation: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.request.url?.scheme == "about" || navigationAction.request.url == nil ? .allow : .cancel
    }
}
