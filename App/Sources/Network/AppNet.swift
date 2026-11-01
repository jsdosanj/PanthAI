import Foundation
import Observation

/// Every request DosanjhAI makes goes through `AppNet.session`, which records it in the activity log
/// and enforces the offline switch. (Apple's Private Cloud Compute model and sign-in sheets are
/// handled by iPadOS itself, so they don't appear here.)
enum AppNet {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = [NetGuardProtocol.self] + (configuration.protocolClasses ?? [])
        return URLSession(configuration: configuration)
    }()
}

enum NetPolicy {
    static var offline: Bool { UserDefaults.standard.bool(forKey: Prefs.offline) }
    static var allowLocalWhenOffline: Bool { UserDefaults.standard.object(forKey: Prefs.offlineAllowLocal) as? Bool ?? true }

    /// Addresses on your own network or tailnet: localhost, .local, private ranges, Tailscale (100.64/10 and *.ts.net).
    static func isLocal(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h.isEmpty { return false }
        if h == "localhost" || h.hasSuffix(".local") || h.hasSuffix(".ts.net") { return true }
        if h.contains(":") { return h == "::1" || h.hasPrefix("fe80:") || h.hasPrefix("fc") || h.hasPrefix("fd") }   // IPv6: loopback, link-local, unique-local only
        let labels = h.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = labels.compactMap { Int($0) }
        if numbers.count != labels.count { return labels.count == 1 }   // a bare name like "my-mac"; a dotted name with letters is public
        guard numbers.count == 4, numbers.allSatisfy({ (0...255).contains($0) }) else { return false }
        let parts = numbers
        return parts[0] == 10 || parts[0] == 127 || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 100 && (64...127).contains(parts[1]))
    }

    static func blocks(_ url: URL) -> Bool {
        guard offline else { return false }
        return !(allowLocalWhenOffline && isLocal(url.host ?? ""))
    }

    static func purpose(for host: String) -> String {
        switch host {
        case "api.github.com", "api.githubcopilot.com", "models.github.ai": "GitHub"
        case "huggingface.co", "cdn-lfs.huggingface.co", "cas-bridge.xethub.hf.co": "Model download"
        case "api.anthropic.com": "Claude API"
        case "api.openai.com": "OpenAI API"
        case "openrouter.ai": "OpenRouter"
        case "html.duckduckgo.com", "api.search.brave.com": "Web search"
        default: isLocal(host) ? "Your network" : "Web or connector"
        }
    }
}

struct NetEntry: Identifiable {
    let id = UUID()
    let date: Date
    let method: String
    let host: String
    let path: String        // query strings are never recorded
    let purpose: String
    var bytesOut: Int
    var bytesIn = 0
    var status: String      // "200", "Blocked", "Failed"
}

@MainActor @Observable
final class NetLog {
    static let shared = NetLog()
    private(set) var entries: [NetEntry] = []
    private(set) var totalIn = 0
    private(set) var totalOut = 0

    func add(_ entry: NetEntry) {
        entries.insert(entry, at: 0)
        if entries.count > 500 { entries.removeLast() }
        totalOut += entry.bytesOut
    }

    func finish(_ id: UUID, bytesIn: Int, status: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].bytesIn = bytesIn
        entries[i].status = status
        totalIn += bytesIn
    }

    func clear() { entries = []; totalIn = 0; totalOut = 0 }
}

/// Sits in front of every request: logs it, blocks it in offline mode, otherwise passes it through untouched.
final class NetGuardProtocol: URLProtocol, URLSessionDataDelegate, @unchecked Sendable {
    private static let handledKey = "DosanjhAI.handled"
    private var innerTask: URLSessionDataTask?
    private var entryID: UUID?
    private var received = 0
    private var status = "Failed"

    override class func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return URLProtocol.property(forKey: handledKey, in: request) == nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let entry = NetEntry(date: .now, method: request.httpMethod ?? "GET", host: url.host ?? "?", path: url.path,
                             purpose: NetPolicy.purpose(for: url.host ?? ""), bytesOut: request.httpBody?.count ?? 0, status: "…")
        entryID = entry.id
        Task { @MainActor in NetLog.shared.add(entry) }

        if NetPolicy.blocks(url) {
            status = "Blocked"
            let error = URLError(.notConnectedToInternet, userInfo: [NSLocalizedDescriptionKey: "Offline mode is on. Turn it off in Settings › Privacy & Network to use the network."])
            client?.urlProtocol(self, didFailWithError: error)
            finishLog()
            return
        }
        let mutable = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutable)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil   // authenticated responses must not land in a shared disk cache
        let inner = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        innerTask = inner.dataTask(with: mutable as URLRequest)
        innerTask?.resume()
    }

    override func stopLoading() { innerTask?.cancel() }

    /// Every hop is checked again, and credentials never follow a redirect to another host.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, !NetPolicy.blocks(url) else { completionHandler(nil); return }
        var next = request
        if url.host != task.originalRequest?.url?.host {
            for header in ["Authorization", "x-api-key", "X-Subscription-Token", "Mcp-Session-Id", "api-key"] { next.setValue(nil, forHTTPHeaderField: header) }
        }
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = String((response as? HTTPURLResponse)?.statusCode ?? 0)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        received += data.count
        client?.urlProtocol(self, didLoad: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { client?.urlProtocol(self, didFailWithError: error) } else { client?.urlProtocolDidFinishLoading(self) }
        finishLog()
        session.finishTasksAndInvalidate()
    }

    private func finishLog() {
        guard let id = entryID else { return }
        let (bytes, status) = (received, status)
        Task { @MainActor in NetLog.shared.finish(id, bytesIn: bytes, status: status) }
    }
}
