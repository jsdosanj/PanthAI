import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Documents and photos the assistant can search. Everything here stays on this iPad.
struct KnowledgeView: View {
    @Query(sort: \KnowledgeSource.addedAt, order: .reverse) private var sources: [KnowledgeSource]
    @AppStorage(Prefs.knowledge) private var enabled = true
    @AppStorage(Prefs.knowledgeAuto) private var autoUse = true
    @State private var importer = KnowledgeImporter.shared
    @State private var picking = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var stats = KnowledgeStats()
    @State private var query = ""
    @State private var hits: [KnowledgeHit] = []
    @State private var confirmClear = false
    @State private var dropTargeted = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Let the assistant use Knowledge", isOn: $enabled)
                    Toggle("Look up my documents in chats automatically", isOn: $autoUse).disabled(!enabled)
                } footer: {
                    Text("Only text is kept, never the original files. It's stored on this iPad, isn't synced to iCloud and isn't included in backups. Code sessions use a search tool instead, and ask before changing anything after reading a document.")
                }

                Section {
                    Button("Add files…", systemImage: "doc.badge.plus") { picking = true }
                    PhotosPicker(selection: $photos, maxSelectionCount: 20, matching: .images) { Label("Add photos…", systemImage: "photo.badge.plus") }
                    if importer.working > 0 { HStack { ProgressView(); Text("Reading \(importer.working) item\(importer.working == 1 ? "" : "s")…").foregroundStyle(.secondary) } }
                    if let message = importer.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                } header: {
                    Text("Add")
                } footer: {
                    Text("Text files, notes, code, PDFs (scanned pages are read with text recognition) and photos (text in them is read, and what they show is noted). You can also drop files here.")
                }

                Section {
                    if sources.isEmpty {
                        Text("Nothing added yet.").foregroundStyle(.secondary)
                    }
                    ForEach(sources) { source in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(source.name, systemImage: source.icon).lineLimit(1)
                            Text("\(source.chunkCount) passages · \(source.characters.formatted()) characters" + (source.note.isEmpty ? "" : " · \(source.note)"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { sources[$0].id }
                        Task { for id in ids { try? await KnowledgeIndex.shared.remove(id) }; stats = await KnowledgeIndex.shared.stats() }
                    }
                } header: {
                    Text("Sources")
                } footer: {
                    Text(summary)
                }

                if !sources.isEmpty {
                    Section("Try a search") {
                        TextField("Ask something your documents answer", text: $query).onSubmit { Task { hits = await KnowledgeIndex.shared.search(query, limit: 5) } }
                        ForEach(hits) { hit in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(hit.locator.isEmpty ? hit.sourceName : "\(hit.sourceName) · \(hit.locator)").font(.caption.bold())
                                Text(hit.text).font(.footnote).lineLimit(5)
                            }
                        }
                    }
                    Section { Button("Remove everything…", role: .destructive) { confirmClear = true } }
                }
            }
            .navigationTitle("Knowledge")
            .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 16).strokeBorder(.tint, style: StrokeStyle(lineWidth: 3, dash: [8])).padding(8).allowsHitTesting(false) } }
            .dropDestination(for: URL.self, action: { urls, _ in KnowledgeImporter.shared.importFiles(urls); return true }, isTargeted: { dropTargeted = $0 })
            .fileImporter(isPresented: $picking, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { KnowledgeImporter.shared.importFiles(urls) }
                else if case .failure(let error) = result { importer.message = error.localizedDescription }
            }
            .onChange(of: photos) { _, items in
                guard !items.isEmpty else { return }
                KnowledgeImporter.shared.importPhotos(items)
                photos = []
            }
            .confirmationDialog("Remove everything from Knowledge?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Remove All", role: .destructive) { Task { try? await KnowledgeIndex.shared.removeAll(); stats = await KnowledgeIndex.shared.stats() } }
            } message: { Text("This can't be undone. Your original files aren't touched.") }
            .task(id: sources.count) { stats = await KnowledgeIndex.shared.stats() }
        }
        .modelContainer(KnowledgeData.container)
    }

    private var summary: String {
        let mode = Embedder.available
            ? "Search uses meaning and keywords."
            : "Search uses keywords only (the on-device language model isn't available)."
        return "\(stats.sources) source\(stats.sources == 1 ? "" : "s"), \(stats.passages.formatted()) passages. \(mode)"
    }
}
