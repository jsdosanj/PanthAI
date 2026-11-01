import SwiftData
import SwiftUI

/// A reusable prompt with {{variables}} the user fills in before it is inserted.
@Model
final class PromptTemplate {
    var id: UUID = UUID()
    var name: String = ""
    var body: String = ""
    var createdAt: Date = Date.now

    init(name: String, body: String) {
        self.name = name
        self.body = body
    }

    var variables: [String] {
        let regex = try? NSRegularExpression(pattern: #"\{\{\s*([A-Za-z0-9_ ]+?)\s*\}\}"#)
        let range = NSRange(body.startIndex..., in: body)
        var seen: [String] = []
        for m in regex?.matches(in: body, range: range) ?? [] {
            if let r = Range(m.range(at: 1), in: body) { let name = String(body[r]); if !seen.contains(name) { seen.append(name) } }
        }
        return seen
    }

    func filled(_ values: [String: String]) -> String {
        var text = body
        for (key, value) in values {
            text = text.replacingOccurrences(of: #"\{\{\s*\#(NSRegularExpression.escapedPattern(for: key))\s*\}\}"#, with: NSRegularExpression.escapedTemplate(for: value), options: .regularExpression)
        }
        return text
    }

    static let starters: [(String, String)] = [
        ("Review this code", "Review the following {{language}} code for bugs, edge cases and readability. List problems by severity, then show a corrected version.\n\n{{code}}"),
        ("Explain simply", "Explain {{topic}} to someone who knows {{background}}. Use one analogy and one short example."),
        ("Commit message", "Write a concise conventional commit message for this diff:\n\n{{diff}}"),
        ("Translate", "Translate this into {{language}}, keeping the tone and any technical terms:\n\n{{text}}"),
        ("Summarise paper", "Summarise this paper for a researcher: the claim, method, results, limits and what to read next.\n\n{{text}}"),
    ]
}

/// ⋯ in the composer: pick a template, fill its variables, insert it.
struct TemplatePicker: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \PromptTemplate.createdAt) private var templates: [PromptTemplate]
    let onInsert: (String) -> Void
    @State private var chosen: PromptTemplate?
    @State private var values: [String: String] = [:]

    var body: some View {
        NavigationStack {
            Group {
                if let chosen {
                    Form {
                        ForEach(chosen.variables, id: \.self) { name in
                            TextField(name.capitalized, text: Binding(get: { values[name] ?? "" }, set: { values[name] = $0 }), axis: .vertical).lineLimit(1...8)
                        }
                        Button("Insert") { onInsert(chosen.filled(values)); dismiss() }.buttonStyle(.borderedProminent)
                    }
                    .navigationTitle(chosen.name)
                } else {
                    List(templates) { template in
                        Button {
                            if template.variables.isEmpty { onInsert(template.body); dismiss() } else { chosen = template }
                        } label: {
                            VStack(alignment: .leading) { Text(template.name); Text(template.body).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        }
                    }
                    .overlay { if templates.isEmpty { ContentUnavailableView("No templates", systemImage: "text.badge.plus", description: Text("Add some in Settings.")) } }
                    .navigationTitle("Templates")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(chosen == nil ? "Close" : "Back") { if chosen == nil { dismiss() } else { chosen = nil } } } }
        }
        .presentationDetents([.medium, .large])
    }
}

struct TemplatesSection: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \PromptTemplate.createdAt) private var templates: [PromptTemplate]

    var body: some View {
        Section {
            ForEach(templates) { template in
                NavigationLink(template.name) {
                    Form {
                        TextField("Name", text: Bindable(template).name)
                        TextField("Prompt — use {{variables}}", text: Bindable(template).body, axis: .vertical).lineLimit(5...20).font(.body.monospaced())
                    }
                    .navigationTitle(template.name)
                }
            }
            .onDelete { offsets in for i in offsets { context.delete(templates[i]) }; try? context.save() }
            Button("New template…", systemImage: "plus") { context.insert(PromptTemplate(name: "New template", body: "{{input}}")); try? context.save() }
        } header: { Text("Prompt templates") } footer: { Text("Insert them from the composer. Put variables in double braces, like {{code}}.") }
        .task {
            if templates.isEmpty && !UserDefaults.standard.bool(forKey: "templates.seeded") {
                for (name, body) in PromptTemplate.starters { context.insert(PromptTemplate(name: name, body: body)) }
                try? context.save()
                UserDefaults.standard.set(true, forKey: "templates.seeded")
            }
        }
    }
}
