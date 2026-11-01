import SwiftUI
import UIKit

/// Renders model output: inline markdown plus fenced code blocks with a copy button.
struct MarkdownText: View {
    let text: String

    private enum Block: Identifiable {
        case prose(String), code(language: String, body: String)
        var id: String {
            switch self {
            case .prose(let s): "p\(s.hashValue)"
            case .code(_, let b): "c\(b.hashValue)"
            }
        }
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var prose: [String] = []
        var code: [String] = []
        var language = ""
        var inCode = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("```") {
                if inCode { result.append(.code(language: language, body: code.joined(separator: "\n"))); code = []; inCode = false }
                else {
                    if !prose.isEmpty { result.append(.prose(prose.joined(separator: "\n"))); prose = [] }
                    language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    inCode = true
                }
            } else if inCode { code.append(line) } else { prose.append(line) }
        }
        if inCode { result.append(.code(language: language, body: code.joined(separator: "\n"))) }   // still streaming
        if !prose.isEmpty { result.append(.prose(prose.joined(separator: "\n"))) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { block in
                switch block {
                case .prose(let s):
                    Text((try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s))
                        .textSelection(.enabled)
                case .code(let language, let body):
                    CodeBlock(language: language, code: body)
                }
            }
        }
    }
}

private struct CodeBlock: View {
    let language: String
    let code: String
    @State private var copied = false
    @State private var previewing = false
    private var previewable: Bool { ["html", "svg"].contains(language.lowercased()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                if previewable {
                    Button(previewing ? "Code" : "Preview", systemImage: previewing ? "chevron.left.forwardslash.chevron.right" : "eye") { previewing.toggle() }
                        .font(.caption).buttonStyle(.borderless).frame(minHeight: 44)
                }
                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    UIPasteboard.general.string = code
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                }
                .font(.caption).buttonStyle(.borderless).foregroundStyle(.secondary).frame(minHeight: 44)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.quaternary.opacity(0.5))
            if previewing {
                ArtifactPreview(html: language.lowercased() == "svg" ? "<html><body style='margin:0;display:grid;place-items:center'>\(code)</body></html>" : code)
                    .frame(height: 360)
            } else {
                ScrollView(.horizontal) {
                    Text(code).font(.system(.callout, design: .monospaced)).textSelection(.enabled).padding(12)
                }
            }
        }
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }
}
