import Foundation
import UserNotifications

/// Downloads a model's files with a *background* URLSession, so a multi-GB download keeps going when you
/// switch apps, lock the iPad, or close PanthAI. Files are checked against the sizes Hugging Face reports
/// and only then moved into place; a folder counts as downloaded once every file is there.
///
/// A background session can't use `AppNet`'s URLProtocol, so the offline switch and the activity log are
/// applied here by hand.
final class ModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = ModelDownloader()
    static let sessionID = "com.dosanjhlabs.panthai.models"

    /// iPadOS hands this over when it relaunches the app to finish a background session.
    var backgroundCompletion: (() -> Void)?

    struct Plan: Codable {
        struct File: Codable { var name: String; var size: Int }
        var repo: String
        var files: [File]
        var total: Int { files.reduce(0) { $0 + $1.size } }
    }

    private let lock = NSLock()
    private var inflight: [Int: Int] = [:]               // task id -> bytes received so far
    private var waiters: [String: [CheckedContinuation<Void, Error>]] = [:]
    private var failures: [String: String] = [:]
    private var lastPublished: [String: Double] = [:]

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        configuration.isDiscretionary = false             // the user asked for this; don't wait for power and Wi-Fi
        configuration.sessionSendsLaunchEvents = true
        configuration.allowsCellularAccess = true
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    // MARK: Where things live

    static var root: URL {
        var dir = URL.applicationSupportDirectory.appending(path: "Models/Downloads", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }

    static func directory(for repo: String) -> URL {
        root.appending(path: repo.replacingOccurrences(of: "/", with: "__"), directoryHint: .isDirectory)
    }

    private static func planURL(_ repo: String) -> URL { directory(for: repo).appending(path: ".plan.json") }
    private static func doneURL(_ repo: String) -> URL { directory(for: repo).appending(path: ".complete") }

    static func isComplete(_ repo: String) -> Bool { FileManager.default.fileExists(atPath: doneURL(repo).path) }

    private static func plan(for repo: String) -> Plan? {
        (try? Data(contentsOf: planURL(repo))).flatMap { try? JSONDecoder().decode(Plan.self, from: $0) }
    }

    /// Only these files are needed to run a model; images, READMEs and training leftovers are skipped.
    static func wanted(_ name: String) -> Bool {
        guard !name.hasPrefix("."), !name.contains("..") else { return false }
        let lower = name.lowercased()
        if lower.hasPrefix("onnx/") || lower.hasPrefix("original/") { return false }
        return ["safetensors", "json", "txt", "model", "jinja", "tiktoken"].contains((lower as NSString).pathExtension)
    }

    // MARK: Starting

    /// Resolves once every file of `repo` is on disk. Safe to call again for a download already running.
    func download(repo: String) async throws {
        if Self.isComplete(repo) { return }
        guard repo.split(separator: "/").count == 2, !repo.contains("..") else { throw RemoteError(message: "That isn't a valid model name.") }
        guard let listURL = URL(string: "https://huggingface.co/api/models/\(repo)?blobs=true") else { throw RemoteError(message: "That isn't a valid model name.") }
        if await MainActor.run(body: { NetPolicy.blocks(listURL) }) { throw RemoteError(message: "Offline mode is on, so models can't be downloaded.") }

        var plan = Self.plan(for: repo)
        if plan == nil {
            let (data, response) = try await AppNet.session.data(from: listURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let json = JSONValue.parse(String(decoding: data, as: UTF8.self)) else {
                throw RemoteError(message: "Couldn't read the file list for \(repo).")
            }
            let files = (json["siblings"]?.array ?? []).compactMap { entry -> Plan.File? in
                guard let name = entry["rfilename"]?.string, Self.wanted(name) else { return nil }
                return Plan.File(name: name, size: entry["size"]?.int ?? 0)
            }
            guard files.contains(where: { $0.name == "config.json" }), files.contains(where: { $0.name.hasSuffix(".safetensors") }) else {
                throw RemoteError(message: "\(repo) doesn't look like an MLX model.")
            }
            let made = Plan(repo: repo, files: files)
            try FileManager.default.createDirectory(at: Self.directory(for: repo), withIntermediateDirectories: true)
            try JSONEncoder().encode(made).write(to: Self.planURL(repo))
            plan = made
        }
        guard let plan else { return }

        lock.withLock { failures[repo] = nil }
        let running = await runningNames(repo)
        for file in plan.files where !Self.hasFile(file, repo: repo) && !running.contains(file.name) {
            guard let url = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file.name.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/"))") else { continue }
            let task = session.downloadTask(with: url)
            task.taskDescription = repo + "|" + file.name
            task.resume()
        }
        publish(repo: repo, force: true)
        if Self.finishIfComplete(repo) { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.withLock { waiters[repo, default: []].append(continuation) }
            // The last file may have landed while the continuation was being registered.
            if Self.isComplete(repo) { resolve(repo, error: nil) }
        }
    }

    func cancel(repo: String) {
        session.getAllTasks { tasks in
            for task in tasks where task.taskDescription?.hasPrefix(repo + "|") == true { task.cancel() }
        }
        resolve(repo, error: CancellationError())
    }

    /// Call at launch: reconnects to downloads that carried on while the app was closed.
    func reconnect() {
        session.getAllTasks { [weak self] tasks in
            let repos = Set(tasks.compactMap { $0.taskDescription?.split(separator: "|").first.map(String.init) })
            for repo in repos { self?.publish(repo: repo, force: true) }
        }
    }

    private func runningNames(_ repo: String) async -> Set<String> {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                continuation.resume(returning: Set(tasks.compactMap { task in
                    guard let d = task.taskDescription, d.hasPrefix(repo + "|") else { return nil }
                    return String(d.dropFirst(repo.count + 1))
                }))
            }
        }
    }

    private static func hasFile(_ file: Plan.File, repo: String) -> Bool {
        let url = directory(for: repo).appending(path: file.name)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int else { return false }
        return file.size == 0 || size == file.size
    }

    @discardableResult
    private static func finishIfComplete(_ repo: String) -> Bool {
        guard let plan = plan(for: repo), plan.files.allSatisfy({ hasFile($0, repo: repo) }) else { return false }
        FileManager.default.createFile(atPath: doneURL(repo).path, contents: Data())
        return true
    }

    // MARK: Progress

    private func publish(repo: String, force: Bool = false) {
        guard let plan = Self.plan(for: repo), plan.total > 0 else { return }
        var received = plan.files.filter { Self.hasFile($0, repo: repo) }.reduce(0) { $0 + $1.size }
        received += lock.withLock { inflight.values.reduce(0, +) }
        let fraction = min(0.999, Double(received) / Double(plan.total))
        let shouldSend: Bool = lock.withLock {
            let previous = lastPublished[repo] ?? -1
            guard force || fraction - previous >= 0.005 else { return false }
            lastPublished[repo] = fraction
            return true
        }
        guard shouldSend else { return }
        Task { @MainActor in ModelManager.shared.downloadProgress(repo: repo, fraction: fraction) }
    }

    private func resolve(_ repo: String, error: Error?) {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            let list = waiters[repo] ?? []
            waiters[repo] = nil
            return list
        }
        for continuation in pending { if let error { continuation.resume(throwing: error) } else { continuation.resume() } }
        Task { @MainActor in ModelManager.shared.downloadFinished(repo: repo, error: error) }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let repo = downloadTask.taskDescription?.split(separator: "|").first.map(String.init) else { return }
        lock.withLock { inflight[downloadTask.taskIdentifier] = Int(totalBytesWritten) }
        publish(repo: repo)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let description = downloadTask.taskDescription, let bar = description.firstIndex(of: "|") else { return }
        let repo = String(description[..<bar]), name = String(description[description.index(after: bar)...])
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        defer { lock.withLock { _ = inflight.removeValue(forKey: downloadTask.taskIdentifier) } }
        guard status == 200, Self.wanted(name), let plan = Self.plan(for: repo), let file = plan.files.first(where: { $0.name == name }) else {
            lock.withLock { failures[repo] = "Hugging Face answered \(status) for \(name)." }
            log(downloadTask, bytes: 0, status: status == 0 ? "Failed" : String(status))
            return
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size]) as? Int ?? 0
        guard file.size == 0 || size == file.size else {
            lock.withLock { failures[repo] = "\(name) arrived incomplete (\(size) of \(file.size) bytes). Try again." }
            log(downloadTask, bytes: size, status: "Failed")
            return
        }
        let destination = Self.directory(for: repo).appending(path: name)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)   // must happen now; the temp file is deleted when this returns
            log(downloadTask, bytes: size, status: "200")
        } catch {
            lock.withLock { failures[repo] = error.localizedDescription }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let repo = task.taskDescription?.split(separator: "|").first.map(String.init) else { return }
        lock.withLock { _ = inflight.removeValue(forKey: task.taskIdentifier) }
        if let error, (error as? URLError)?.code != .cancelled {
            lock.withLock { failures[repo] = error.localizedDescription }
        }
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            let stillRunning = tasks.contains { $0.state == .running && $0.taskDescription?.hasPrefix(repo + "|") == true }
            guard !stillRunning else { return }
            if Self.finishIfComplete(repo) {
                self.resolve(repo, error: nil)
                self.notifyDone(repo)
            } else if let message = self.lock.withLock({ self.failures[repo] }) {
                self.resolve(repo, error: RemoteError(message: message))
            }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            self?.backgroundCompletion?()
            self?.backgroundCompletion = nil
        }
    }

    // MARK: Side effects

    private func log(_ task: URLSessionTask, bytes: Int, status: String) {
        guard let url = task.originalRequest?.url else { return }
        Task { @MainActor in
            let entry = NetEntry(date: .now, method: "GET", host: url.host ?? "", path: url.path, purpose: "Model download", bytesOut: 0, bytesIn: 0, status: status)
            NetLog.shared.add(entry)
            NetLog.shared.finish(entry.id, bytesIn: bytes, status: status)
        }
    }

    /// The only time a notification matters here is when you've left the app while it finished.
    private func notifyDone(_ repo: String) {
        Task { @MainActor in
            Notifier.post(.project, title: "Model ready", body: "\(repo.split(separator: "/").last.map(String.init) ?? repo) finished downloading.", chatID: nil)
        }
    }
}
