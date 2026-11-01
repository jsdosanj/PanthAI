import SwiftUI
import UniformTypeIdentifiers

/// Chats as Markdown or JSON files, handed to the share sheet when you choose Share.
enum ChatExporter {
    static func markdown(title: String, turns: [ChatTurn], model: String) -> String {
        var out = "# \(title)\n\n_Model: \(model)_\n\n"
        for turn in turns {
            switch turn.role {
            case .user: out += "## You\n\n\(turn.text)\n\n"
            case .assistant: out += "## Assistant\n\n\(ToolProtocol.stripCall(from: turn.text))\n\n"
            case .tool: out += "> **Tool \(turn.toolName ?? "")** — \(turn.toolStatus?.rawValue ?? "")\n>\n> " + turn.text.prefix(600).replacingOccurrences(of: "\n", with: "\n> ") + "\n\n"
            }
        }
        return out
    }

    static func json(title: String, turns: [ChatTurn], model: String) -> Data {
        struct Out: Encodable { let title: String; let model: String; let exported: Date; let messages: [ChatTurn] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(Out(title: title, model: model, exported: .now, messages: turns))) ?? Data()
    }
}

struct ChatFile: Transferable {
    enum Format { case markdown, json }
    let title: String
    let turns: [ChatTurn]
    let model: String
    let format: Format

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { item in
            let name = item.title.replacingOccurrences(of: "/", with: "-").prefix(40) + (item.format == .markdown ? ".md" : ".json")
            let url = FileManager.default.temporaryDirectory.appending(path: String(name))
            let data = item.format == .markdown ? Data(ChatExporter.markdown(title: item.title, turns: item.turns, model: item.model).utf8)
                                                 : ChatExporter.json(title: item.title, turns: item.turns, model: item.model)
            try data.write(to: url)
            return SentTransferredFile(url)
        }
    }
}
