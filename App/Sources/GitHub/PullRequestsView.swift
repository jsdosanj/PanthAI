import SwiftData
import SwiftUI

/// Review pull requests: read the diff, ask the model for a summary, comment on lines, submit a review.
struct PullRequestsView: View {
    @Query(sort: \WorkspaceRecord.importedAt, order: .reverse) private var repos: [WorkspaceRecord]
    @State private var repo = ""
    @State private var prs: [JSONValue] = []
    @State private var error: String?
    @State private var loading = false
    private let client = GitHubClient()

    private var repoNames: [String] { Array(Set(repos.map(\.fullName))).sorted() }

    var body: some View {
        List {
            Section {
                Picker("Repo", selection: $repo) { Text("Choose…").tag(""); ForEach(repoNames, id: \.self) { Text($0).tag($0) } }
                TextField("or owner/name", text: $repo).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button(loading ? "Loading…" : "Load open pull requests", systemImage: "arrow.triangle.pull") { Task { await load() } }.disabled(repo.isEmpty || loading)
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            Section("Open pull requests") {
                ForEach(Array(prs.enumerated()), id: \.offset) { _, pr in
                    if let number = pr["number"]?.int {
                        NavigationLink { PullRequestDetail(repo: repo, number: number) } label: {
                            VStack(alignment: .leading) {
                                Text("#\(number) \(pr["title"]?.string ?? "")")
                                Text("\(pr["user"]?["login"]?.string ?? "") · \(pr["head"]?["ref"]?.string ?? "") → \(pr["base"]?["ref"]?.string ?? "")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Pull requests")
        .onAppear { if repo.isEmpty { repo = repoNames.first ?? "" } }
    }

    private func load() async {
        loading = true; error = nil
        do { prs = try await client.json("/repos/\(repo)/pulls?state=open&per_page=50").array ?? [] }
        catch { self.error = error.localizedDescription }
        loading = false
    }
}

struct PullRequestDetail: View {
    let repo: String
    let number: Int
    @Query(sort: \ProviderRecord.createdAt) private var providers: [ProviderRecord]
    @State private var pr: JSONValue = .null
    @State private var files: [JSONValue] = []
    @State private var summary = ""
    @State private var summarising = false
    @State private var model: ProviderChoice = .lastUsed
    @State private var commenting: (path: String, line: Int)?
    @State private var commentText = ""
    @State private var reviewBody = ""
    @State private var status = ""
    private let client = GitHubClient()

    var body: some View {
        List {
            Section {
                Text(pr["title"]?.string ?? "").font(.headline)
                if let body = pr["body"]?.string, !body.isEmpty { Text(body).font(.callout) }
            }
            Section("AI summary") {
                Picker("Model", selection: $model) { ForEach(ModelPool.options(providers: providers), id: \.self) { Text($0.label).tag($0) } }
                Button(summarising ? "Reading…" : "Summarise and flag risks", systemImage: "sparkles") { Task { await summarise() } }.disabled(summarising)
                if !summary.isEmpty { MarkdownText(text: summary) }
            }
            ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                if let path = file["filename"]?.string {
                    Section(path) {
                        let lines = DiffLineParser.parse(file["patch"]?.string ?? "")
                        ForEach(lines) { line in
                            Button {
                                if let n = line.newLine { commenting = (path, n); commentText = "" }
                            } label: {
                                HStack(alignment: .top, spacing: 6) {
                                    Text(line.newLine.map(String.init) ?? "").frame(width: 36, alignment: .trailing).foregroundStyle(.secondary)
                                    Text(line.text.isEmpty ? " " : line.text)
                                }
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(line.kind == .added ? Color.green.opacity(0.18) : (line.kind == .removed ? Color.red.opacity(0.18) : (line.kind == .hunk ? Color.blue.opacity(0.12) : .clear)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            Section("Submit review") {
                TextField("Review comment", text: $reviewBody, axis: .vertical).lineLimit(2...8)
                HStack {
                    Button("Comment") { Task { await submit("COMMENT") } }
                    Button("Approve") { Task { await submit("APPROVE") } }
                    Button("Request changes", role: .destructive) { Task { await submit("REQUEST_CHANGES") } }
                }.buttonStyle(.bordered)
                if !status.isEmpty { Text(status).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("#\(number)")
        .task { await load() }
        .alert("Comment on line \(commenting?.line ?? 0)", isPresented: Binding(get: { commenting != nil }, set: { if !$0 { commenting = nil } })) {
            TextField("Comment", text: $commentText, axis: .vertical)
            Button("Post") { Task { await postComment() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text(commenting?.path ?? "") }
    }

    private func load() async {
        pr = (try? await client.json("/repos/\(repo)/pulls/\(number)")) ?? .null
        files = (try? await client.json("/repos/\(repo)/pulls/\(number)/files?per_page=60").array) ?? []
    }

    private func summarise() async {
        summarising = true
        let diff = files.compactMap { f in f["patch"]?.string.map { "--- \(f["filename"]?.string ?? "")\n\($0)" } }.joined(separator: "\n")
        let ask = "Review this pull request.\nTitle: \(pr["title"]?.string ?? "")\n\n\(String(diff.prefix(12_000)))\n\nGive: a 2-sentence summary, then a bulleted list of bugs, risks and missing tests, with file names."
        summary = await Generator.run(model, prompt: ask).text
        summarising = false
    }

    private func postComment() async {
        guard let target = commenting, let sha = pr["head"]?["sha"]?.string else { return }
        do {
            _ = try await client.send("POST", "/repos/\(repo)/pulls/\(number)/comments",
                                      body: ["body": .string(commentText), "commit_id": .string(sha), "path": .string(target.path), "line": .number(Double(target.line)), "side": .string("RIGHT")])
            status = "Comment posted on \(target.path):\(target.line)."
        } catch { status = error.localizedDescription }
        commenting = nil
    }

    private func submit(_ event: String) async {
        do {
            _ = try await client.send("POST", "/repos/\(repo)/pulls/\(number)/reviews", body: ["body": .string(reviewBody), "event": .string(event)])
            status = "Review submitted (\(event.lowercased().replacingOccurrences(of: "_", with: " ")))."
        } catch { status = error.localizedDescription }
    }
}

struct DiffLineParser {
    struct Line: Identifiable { let id = UUID(); let kind: Kind; let text: String; let newLine: Int? ; enum Kind { case context, added, removed, hunk } }

    static func parse(_ patch: String) -> [Line] {
        var newLine = 0
        var out: [Line] = []
        for raw in patch.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if raw.hasPrefix("@@") {
                if let m = raw.range(of: #"\+(\d+)"#, options: .regularExpression), let n = Int(raw[m].dropFirst()) { newLine = n }
                out.append(Line(kind: .hunk, text: raw, newLine: nil))
            } else if raw.hasPrefix("+") { out.append(Line(kind: .added, text: String(raw.dropFirst()), newLine: newLine)); newLine += 1 }
            else if raw.hasPrefix("-") { out.append(Line(kind: .removed, text: String(raw.dropFirst()), newLine: nil)) }
            else { out.append(Line(kind: .context, text: raw.hasPrefix(" ") ? String(raw.dropFirst()) : raw, newLine: newLine)); newLine += 1 }
        }
        return out
    }
}
