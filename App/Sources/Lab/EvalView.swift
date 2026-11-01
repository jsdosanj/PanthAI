import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// A set of prompts with expected answers. Saved as JSON in the Files app (On My iPad › PanthAI › Evals).
struct EvalSuite: Codable, Identifiable, Hashable {
    struct Case: Codable, Identifiable, Hashable {
        var id = UUID()
        var prompt = ""
        var kind = "contains"       // contains | equals | regex | judge
        var expected = ""
    }
    var id = UUID()
    var name = "New suite"
    var cases: [Case] = [Case()]

    static var folder: URL {
        let url = FilesFolder.root.appending(path: "Evals", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func all() -> [EvalSuite] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { try? JSONDecoder().decode(EvalSuite.self, from: Data(contentsOf: $0)) }.sorted { $0.name < $1.name }
    }
    func save() { try? JSONEncoder().encode(self).write(to: Self.folder.appending(path: "\(id.uuidString).json")) }
    func delete() { try? FileManager.default.removeItem(at: Self.folder.appending(path: "\(id.uuidString).json")) }
}

struct EvalView: View {
    @State private var suites = EvalSuite.all()
    @State private var importing = false

    var body: some View {
        List {
            ForEach(suites) { suite in
                NavigationLink { EvalSuiteView(suite: suite) } label: {
                    VStack(alignment: .leading) { Text(suite.name); Text("\(suite.cases.count) cases").font(.caption).foregroundStyle(.secondary) }
                }
            }
            .onDelete { offsets in for i in offsets { suites[i].delete() }; suites = EvalSuite.all() }
        }
        .overlay { if suites.isEmpty { ContentUnavailableView("No eval suites", systemImage: "checklist", description: Text("Create one, or import a JSON file.")) } }
        .navigationTitle("Evals")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button("New suite", systemImage: "plus") { EvalSuite().save(); suites = EvalSuite.all() } }
            ToolbarItem(placement: .secondaryAction) { Button("Import JSON…", systemImage: "square.and.arrow.down") { importing = true } }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result, url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            if var suite = try? JSONDecoder().decode(EvalSuite.self, from: Data(contentsOf: url)) { suite.id = UUID(); suite.save(); suites = EvalSuite.all() }
        }
        .onAppear { suites = EvalSuite.all() }
    }
}

struct EvalSuiteView: View {
    @State var suite: EvalSuite
    @Query(sort: \ProviderRecord.createdAt) private var providers: [ProviderRecord]
    @State private var selection: Set<ProviderChoice> = [.apple(.onDevice)]
    @State private var judge: ProviderChoice = .apple(.onDevice)
    @State private var results: [String: (pass: Bool, seconds: Double)] = [:]   // "caseID|modelKey"
    @State private var running = false
    @State private var csv: URL?

    private var models: [ProviderChoice] { ProviderModelOrder.sorted(selection) }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $suite.name)
                ForEach($suite.cases) { $item in
                    VStack(alignment: .leading) {
                        TextField("Prompt", text: $item.prompt, axis: .vertical).lineLimit(1...5)
                        HStack {
                            Picker("Check", selection: $item.kind) {
                                Text("contains").tag("contains"); Text("equals").tag("equals"); Text("regex").tag("regex"); Text("judge says pass").tag("judge")
                            }.labelsHidden()
                            TextField(item.kind == "judge" ? "What a good answer does" : "Expected", text: $item.expected).textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                    }
                }
                .onDelete { suite.cases.remove(atOffsets: $0) }
                Button("Add case", systemImage: "plus") { suite.cases.append(.init()) }
            } header: { Text("Cases") }
            Section("Run on") {
                ModelMultiPicker(options: ModelPool.options(providers: providers), selection: $selection)
                Picker("Judge model", selection: $judge) { ForEach(ModelPool.options(providers: providers), id: \.self) { Text($0.label).tag($0) } }
                Button(running ? "Running…" : "Run suite", systemImage: "play.fill") { Task { await run() } }.disabled(running || selection.isEmpty)
            }
            if !results.isEmpty {
                Section("Results") {
                    ForEach(models, id: \.self) { model in
                        let passed = suite.cases.filter { results["\($0.id)|\(model.key)"]?.pass == true }.count
                        LabeledContent(model.label, value: "\(passed)/\(suite.cases.count) passed")
                    }
                    ForEach(suite.cases) { item in
                        VStack(alignment: .leading) {
                            Text(item.prompt).lineLimit(1).font(.callout)
                            HStack { ForEach(models, id: \.self) { m in
                                let r = results["\(item.id)|\(m.key)"]
                                Label(r.map { $0.pass ? "pass" : "fail" } ?? "…", systemImage: r?.pass == true ? "checkmark.circle.fill" : "xmark.circle")
                                    .font(.caption).foregroundStyle(r?.pass == true ? .green : .orange)
                            } }
                        }
                    }
                    if let csv { ShareLink("Export CSV", item: csv) }
                }
            }
        }
        .navigationTitle(suite.name)
        .onChange(of: suite) { _, new in new.save() }
    }

    private func check(_ item: EvalSuite.Case, reply: String) async -> Bool {
        switch item.kind {
        case "equals": return reply.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(item.expected) == .orderedSame
        case "regex": return reply.range(of: item.expected, options: .regularExpression) != nil
        case "judge":
            let ask = "Question: \(item.prompt)\nA good answer: \(item.expected)\nAnswer given: \(reply)\n\nDoes the answer meet the description? Reply with only PASS or FAIL."
            let verdict = await Generator.run(judge, prompt: ask, sampling: SamplingSettings(temperature: 0, maxTokens: 8))
            return verdict.text.uppercased().contains("PASS")
        default: return reply.localizedCaseInsensitiveContains(item.expected)
        }
    }

    private func run() async {
        running = true; results = [:]; csv = nil
        for model in models {
            for item in suite.cases {
                let result = await Generator.run(model, prompt: item.prompt)
                let pass = result.error == nil ? await check(item, reply: result.text) : false
                results["\(item.id)|\(model.key)"] = (pass, result.totalSeconds)
            }
        }
        csv = CSV.file(named: "\(suite.name).csv", rows: [["case", "model", "pass", "seconds"]] + suite.cases.flatMap { item in
            models.map { m in [item.prompt, m.label, results["\(item.id)|\(m.key)"]?.pass == true ? "pass" : "fail", String(results["\(item.id)|\(m.key)"]?.seconds ?? 0)] }
        })
        running = false
    }
}
