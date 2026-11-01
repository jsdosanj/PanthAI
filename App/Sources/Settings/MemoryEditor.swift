import SwiftUI

struct MemoryEditor: View {
    @State private var text = MemoryStore.load()

    var body: some View {
        VStack(alignment: .leading) {
            Text("Notes the assistant saved about you and your work. Edit or delete anything. They stay on this iPad and are added to the assistant's instructions.")
                .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
            TextEditor(text: $text)
                .font(.body.monospaced())
                .padding(.horizontal, 8)
                .onChange(of: text) { _, new in MemoryStore.save(new) }
        }
        .navigationTitle("Memory")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("Clear", role: .destructive) { text = ""; MemoryStore.save("") } } }
    }
}
