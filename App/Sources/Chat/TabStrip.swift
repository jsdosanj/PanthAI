import SwiftUI

/// Safari-style open-chat tabs under the toolbar.
struct TabStrip: View {
    @Bindable var state: WindowState
    let records: [ChatSessionRecord]

    var body: some View {
        if state.openTabs.count > 1 {
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(state.openTabs, id: \.self) { id in
                        if let record = records.first(where: { $0.id == id }) { tab(record) }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private func tab(_ record: ChatSessionRecord) -> some View {
        let active = state.selection == .chat(record.id)
        return HStack(spacing: 6) {
            Button { state.selection = .chat(record.id) } label: {
                Text(record.title).lineLimit(1).frame(maxWidth: 180)
            }
            .buttonStyle(.plain)
            Button("Close tab", systemImage: "xmark") { state.closeTab(record.id, records: records) }
                .labelStyle(.iconOnly).font(.caption).buttonStyle(.borderless).foregroundStyle(.secondary)
                .frame(minWidth: 44, minHeight: 44)
        }
        .font(.subheadline)
        .padding(.leading, 10)
        .frame(minHeight: 44)
        .background(active ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .hoverEffect(.highlight)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}
