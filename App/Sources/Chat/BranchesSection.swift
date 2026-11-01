import SwiftData
import SwiftUI

/// Shows where this chat was branched from and what branched from it.
struct BranchesSection: View {
    let record: ChatSessionRecord
    @Query(sort: \ChatSessionRecord.createdAt) private var all: [ChatSessionRecord]

    var body: some View {
        let parent = all.first { $0.id == record.parentID }
        let children = all.filter { $0.parentID == record.id }
        if parent != nil || !children.isEmpty {
            Section("Branches") {
                if let parent { Button("Branched from: \(parent.title)", systemImage: "arrow.turn.up.left") { AppRouter.shared.chatID = parent.id } }
                ForEach(children) { child in Button(child.title, systemImage: "arrow.triangle.branch") { AppRouter.shared.chatID = child.id } }
            }
        }
    }
}
