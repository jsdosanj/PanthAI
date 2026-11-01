import Foundation
import Testing
@testable import DosanjhAI

struct ToolTests {
    @Test func parsesFencedToolCall() {
        let text = "Let me look.\n```tool\n{\"name\": \"read_file\", \"arguments\": {\"path\": \"a.swift\"}}\n```"
        let call = ToolProtocol.parse(text)
        #expect(call?.name == "read_file")
        #expect(call?.arguments["path"]?.string == "a.swift")
    }

    @Test func ignoresPlainCodeBlocks() {
        #expect(ToolProtocol.parse("```swift\nlet x = 1\n```") == nil)
    }

    @Test func stripsToolBlockFromVisibleText() {
        let text = "Reading it now.\n```tool\n{\"name\":\"x\",\"arguments\":{}}\n```"
        #expect(ToolProtocol.stripCall(from: text) == "Reading it now.")
    }

    @Test func workspacePathRejectsEscapes() {
        let root = URL(filePath: "/tmp/ws")
        #expect(throws: ToolError.self) { try WorkspacePath.resolve("../etc/passwd", root: root) }
        #expect(throws: ToolError.self) { try WorkspacePath.resolve("/etc/passwd", root: root) }
        #expect(throws: ToolError.self) { try WorkspacePath.resolve(".dosanjhai/manifest.json", root: root) }
        #expect((try? WorkspacePath.resolve("src/main.swift", root: root)) != nil)
    }

    @Test func customNetworkModeOnlyAllowsListedHosts() {
        let hosts = ["github.com"]
        #expect(NetworkPolicy.allows(URL(string: "https://api.github.com/x")!, mode: .custom, allowedHosts: hosts))
        #expect(!NetworkPolicy.allows(URL(string: "https://evil.com")!, mode: .custom, allowedHosts: hosts))
        #expect(!NetworkPolicy.allows(URL(string: "https://notgithub.com")!, mode: .custom, allowedHosts: hosts))
        #expect(NetworkPolicy.allows(URL(string: "https://anything.dev")!, mode: .full, allowedHosts: []))
        #expect(!NetworkPolicy.allows(URL(string: "https://github.com")!, mode: .off, allowedHosts: hosts))
    }

    @Test func gitBlobShaMatchesGit() {
        // `printf 'hello\n' | git hash-object --stdin`
        #expect(GitWorkspace.blobSHA(Data("hello\n".utf8)) == "ce013625030ba8dba906f756967f9e9ca394464a")
    }

    @Test func lineDiffMarksChanges() {
        let diff = LineDiff.compute(before: "a\nb\nc", after: "a\nB\nc")
        #expect(diff.contains { $0.kind == .removed && $0.text == "b" })
        #expect(diff.contains { $0.kind == .added && $0.text == "B" })
    }

    @Test func providerChoiceRoundTrips() {
        let id = UUID()
        for choice in [ProviderChoice.apple(.privateCloud), .mlx("mlx-community/x"), .remote(id, "gpt-5|x")] {
            #expect(ProviderChoice(key: choice.key) == choice)
        }
    }

    @Test func contextBudgetKeepsNewestTurns() {
        let turns = (0..<10).map { ChatTurn(role: .user, text: String(repeating: "x", count: 100) + "\($0)") }
        let kept = ContextBudget.trim(turns, maxChars: 350)
        #expect(kept.count == 3)
        #expect(kept.last?.text.hasSuffix("9") == true)
    }
}
