import Foundation

struct GitHubRepo: Identifiable, Decodable, Hashable, Sendable {
    let id: Int
    let fullName: String
    let isPrivate: Bool
    let defaultBranch: String
    let description: String?

    enum CodingKeys: String, CodingKey {
        case id, description
        case fullName = "full_name"
        case isPrivate = "private"
        case defaultBranch = "default_branch"
    }
}

struct GitHubTreeEntry: Decodable, Sendable {
    let path: String
    let type: String      // "blob" | "tree"
    let sha: String
    let size: Int?
}

enum GitHubError: LocalizedError {
    case http(Int, String)
    case notFound
    var errorDescription: String? {
        switch self {
        case .http(let code, let message): "GitHub returned \(code): \(message)"
        case .notFound: "Repository or branch not found. Private repos need a token in Settings."
        }
    }
}

/// Talks to the GitHub REST API. The token (optional for public repos) lives in the Keychain.
struct GitHubClient: Sendable {
    static let tokenAccount = "github.token"
    var token: String? { Keychain.get(Self.tokenAccount) }

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let data = try await raw(path)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func raw(_ path: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.github.com\(path)")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await AppNet.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if status == 404 { throw GitHubError.notFound }
            throw GitHubError.http(status, String(data: data, encoding: .utf8)?.prefix(200).description ?? "")
        }
        return data
    }

    func repos() async throws -> [GitHubRepo] {
        try await get("/user/repos?per_page=100&sort=pushed&affiliation=owner,collaborator,organization_member", as: [GitHubRepo].self)
    }

    func repo(_ fullName: String) async throws -> GitHubRepo {
        try await get("/repos/\(fullName)", as: GitHubRepo.self)
    }

    func branches(_ fullName: String) async throws -> [String] {
        struct Branch: Decodable { let name: String }
        return try await get("/repos/\(fullName)/branches?per_page=100", as: [Branch].self).map(\.name)
    }

    func tree(_ fullName: String, ref: String) async throws -> [GitHubTreeEntry] {
        struct Tree: Decodable { let tree: [GitHubTreeEntry] }
        let encoded = ref.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ref
        return try await get("/repos/\(fullName)/git/trees/\(encoded)?recursive=1", as: Tree.self).tree
    }

    /// The commit a branch points at, and that commit's tree.
    func head(_ fullName: String, branch: String) async throws -> (commit: String, tree: String) {
        let encoded = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch
        let ref = try await get("/repos/\(fullName)/git/ref/heads/\(encoded)", as: JSONValue.self)
        guard let commit = ref["object"]?["sha"]?.string else { throw GitHubError.notFound }
        let detail = try await get("/repos/\(fullName)/git/commits/\(commit)", as: JSONValue.self)
        return (commit, detail["tree"]?["sha"]?.string ?? "")
    }

    func send(_ method: String, _ path: String, body: [String: JSONValue]) async throws -> JSONValue {
        guard let token else { throw GitHubError.http(401, "Add a GitHub token in Settings to make changes.") }
        var request = URLRequest(url: URL(string: "https://api.github.com\(path)")!)
        request.httpMethod = method
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(JSONValue.object(body))
        let (data, response) = try await AppNet.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = JSONValue.parse(String(decoding: data, as: UTF8.self))?["message"]?.string ?? ""
            throw GitHubError.http(status, message)
        }
        return JSONValue.parse(String(decoding: data, as: UTF8.self)) ?? .null
    }

    func json(_ path: String) async throws -> JSONValue { try await get(path, as: JSONValue.self) }

    /// Plain-text endpoints (job logs, diffs).
    func text(_ path: String, accept: String = "application/vnd.github+json") async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.github.com\(path)")!)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await AppNet.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw status == 404 ? GitHubError.notFound : GitHubError.http(status, String(decoding: data.prefix(200), as: UTF8.self)) }
        return String(decoding: data, as: UTF8.self)
    }

    func blob(_ fullName: String, sha: String) async throws -> Data {
        struct Blob: Decodable { let content: String }
        let blob = try await get("/repos/\(fullName)/git/blobs/\(sha)", as: Blob.self)
        let cleaned = blob.content.replacingOccurrences(of: "\n", with: "")
        return Data(base64Encoded: cleaned) ?? Data()
    }
}
