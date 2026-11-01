import UIKit
import SwiftData
import Foundation
import Observation

@MainActor @Observable
final class ChatViewModel {
    let record: ChatSessionRecord
    var turns: [ChatTurn]
    var input = ""
    var isStreaming = false
    var errorMessage: String?
    var tokensPerSecond: Double?
    var isLoadingModel = false
    var workspace: WorkspaceRecord?
    var showRepoPicker = false
    var showHistorySearch = false
    var showHelp = false
    var scrollTick = 0
    var historyCursor: Int?
    private var lastEscape = Date.distantPast
    private var researchRun = false
    /// True once this chat has read content from the web, a connector or a remote machine, which could hide instructions.
    private var tainted = false
    private var schemaRetries = 0
    /// Set by the screen; creates a branch of this chat and opens it. (turn index, edited text for the branch)
    var onBranch: ((Int, String?) -> Void)?
    var requests: [RequestRecord] = []
    /// Running from a Shortcuts automation: no one is there to approve, so anything needing approval is declined.
    var isHeadless = false
    private var stepLimit = ChatViewModel.maxToolSteps
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private(set) var choice: ProviderChoice

    private var provider: (any ModelProvider)?
    private var streamTask: Task<Void, Never>?
    private let save: () -> Void

    var id: UUID { record.id }

    init(record: ChatSessionRecord, save: @escaping () -> Void) {
        self.record = record
        self.turns = record.turns
        self.choice = ProviderChoice(key: record.providerKey)
        self.save = save
        self.provider = Self.makeProvider(for: choice)
        ChatRegistry.register(self)
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appBackgrounded() }
        }
    }

    /// iPadOS doesn't let apps run GPU work in the background, so local models pause; network models can finish.
    private func appBackgrounded() {
        guard isStreaming, case .mlx = choice else { return }
        stop()
        errorMessage = "Paused: local models can't run while the app is in the background. Send your message again to continue."
        Notifier.post(.reply, title: record.title, body: "Paused because the app went to the background. Open it to continue.", chatID: id)
    }

    static func makeProvider(for choice: ProviderChoice) -> (any ModelProvider)? {
        switch choice {
        case .apple(let kind): return FoundationModelsProvider(kind: kind)
        case .mlx(let repo):
            guard let model = CuratedModels.everything.first(where: { $0.id == repo }) else { return nil }
            return ModelManager.shared.makeProvider(for: model)
        case .ssh(let id, let agent):
            let hosts = (try? AppData.container.mainContext.fetch(FetchDescriptor<SSHHostRecord>())) ?? []
            guard let host = hosts.first(where: { $0.id == id }) else { return nil }
            return RemoteAgentProvider(host: host.snapshot, kind: RemoteAgentKind(rawValue: agent) ?? .claude)
        case .remote(let id, let model):
            let records = (try? AppData.container.mainContext.fetch(FetchDescriptor<ProviderRecord>())) ?? []
            guard let record = records.first(where: { $0.id == id }) else { return nil }
            return RemoteProvider(config: RemoteConfig(name: record.name, kind: record.kind, baseURL: record.baseURL, apiKey: record.apiKey, model: model))
        }
    }

    var title: String { record.title }
    var mode: PermissionMode { get { record.mode } set { record.mode = newValue; save() } }
    var promptHistory: [String] { turns.filter { $0.role == .user }.map(\.text) }
    var kind: SessionKind { record.kind }
    var estimatedContextTokens: Int { ContextBudget.estimatedTokens(turns) }

    var status: AppleIntelligenceStatus {
        switch choice {
        case .apple(let kind): AppleIntelligenceStatus.current(kind)
        case .ssh: provider == nil ? .unavailable("That machine was removed. Pick another model.") : .available
        case .remote: provider == nil ? .unavailable("This provider was removed. Pick another model.") : .available
        case .mlx: (provider == nil && !isLoadingModel) ? .unavailable("This model isn't downloaded yet. Get it from the Models tab.") : .available
        }
    }

    /// Switch the engine mid-conversation. The history carries over.
    func select(_ newChoice: ProviderChoice) {
        stop()
        choice = newChoice
        record.providerKey = newChoice.key
        newChoice.remember()
        save()
        provider = Self.makeProvider(for: newChoice)
        guard provider == nil, case .mlx(let repo) = newChoice,
              let model = CuratedModels.everything.first(where: { $0.id == repo }) else { return }
        isLoadingModel = true
        Task {
            await ModelManager.shared.ensureLoaded(model)
            if choice == newChoice { provider = Self.makeProvider(for: newChoice) }
            isLoadingModel = false
            if provider == nil { errorMessage = "Couldn't load \(model.name)." }
        }
    }

    // MARK: Agent loop

    struct PendingApproval: Identifiable {
        let id = UUID()
        let toolName: String
        let summary: String
        let risk: ToolRisk
        let change: FileChange?
        var tainted = false
    }
    enum ApprovalDecision { case allow, allowAlways, deny }

    var pendingApproval: PendingApproval?
    private var approvalContinuation: CheckedContinuation<ApprovalDecision, Never>?
    private var alwaysAllowed: Set<String> = []
    static let maxToolSteps = 10

    /// Sends a prompt with no UI and waits for the whole reply (and any tool steps) to finish.
    func runHeadless(_ prompt: String) async {
        isHeadless = true
        stepLimit = 6
        send(prompt)
        await streamTask?.value
        isHeadless = false
    }

    func resolveApproval(_ decision: ApprovalDecision) {
        approvalContinuation?.resume(returning: decision)
        approvalContinuation = nil
        pendingApproval = nil
    }

    private func requestApproval(_ approval: PendingApproval) async -> ApprovalDecision {
        if isHeadless { return .deny }
        pendingApproval = approval
        Notifier.post(.permission, title: "DosanjhAI needs your OK", body: "\(approval.toolName): \(approval.summary)", chatID: id)
        return await withCheckedContinuation { approvalContinuation = $0 }
    }

    private var toolContext: ToolContext {
        ToolContext(workspaceRoot: workspace?.folderURL, workspaceFullName: workspace?.fullName,
                    workspaceBranch: workspace?.branch, networkMode: record.network, allowedHosts: record.allowedHosts,
                    sshHost: sshHost, memoryAgentID: record.agentID, memoryEnabled: UserDefaults.standard.object(forKey: Prefs.memory) as? Bool ?? true)
    }

    private var connectorTools: [any AgentTool] = []

    private var isRemoteAgent: Bool { if case .ssh = choice { return true } else { return false } }

    private var sshHost: SSHHostSnapshot? {
        guard let id = record.sshHostID else { return nil }
        return ((try? AppData.container.mainContext.fetch(FetchDescriptor<SSHHostRecord>())) ?? []).first { $0.id == id }?.snapshot
    }

    /// Claude Code / Codex over SSH bring their own tools, so DosanjhAI's tool loop stays out of the way.
    private var availableTools: [any AgentTool] {
        isRemoteAgent ? [] : ToolRegistry.tools(kind: record.kind, hasWorkspace: workspace != nil, networkMode: record.network, hasSSH: sshHost != nil) + connectorTools
    }

    private var agent: AgentRecord? {
        guard let id = record.agentID else { return nil }
        return (try? AppData.container.mainContext.fetch(FetchDescriptor<AgentRecord>()))?.first { $0.id == id }
    }

    private var schemaInstruction: String {
        record.schemaText.isEmpty ? "" : "Reply with ONLY a JSON value that matches this JSON Schema, with no other text:\n\(record.schemaText)"
    }

    /// nil when the reply is fine (or no schema is set); otherwise what's wrong with it.
    private func schemaProblem(in text: String) -> String? {
        guard !record.schemaText.isEmpty, let schema = JSONValue.parse(record.schemaText) else { return nil }
        guard let json = SchemaValidator.extractJSON(from: text) else { return "no JSON found in the reply" }
        return SchemaValidator.validate(json, against: schema)
    }

    /// Tool instructions plus the chat's agent persona and notes.
    private var extraInstructions: String { [agent?.promptBlock ?? "", schemaInstruction, toolManual].filter { !$0.isEmpty }.joined(separator: "\n\n") }

    private var toolManual: String { ToolProtocol.manual(for: availableTools.map(\.spec)) }

    /// Connects the connectors this chat switched on and loads their tools (fewer for the small Apple model).
    private func refreshConnectorTools() async {
        let ids = record.enabledConnectors
        guard !ids.isEmpty else { connectorTools = []; return }
        let all = (try? AppData.container.mainContext.fetch(FetchDescriptor<MCPServerRecord>())) ?? []
        let limit: Int = { if case .apple = choice { return 8 } else { return 30 } }()
        connectorTools = await MCPHub.shared.adapters(for: all.filter { ids.contains($0.id) }, limit: limit)
    }

    func send(_ override: String? = nil) {
        let prompt = (override ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isStreaming else { return }
        if override == nil, prompt.hasPrefix("/"), handleSlash(prompt) { input = ""; return }
        if provider == nil { provider = Self.makeProvider(for: choice) }
        guard provider != nil else { errorMessage = "This model isn't loaded. Open the Models tab and load it."; return }
        input = ""
        historyCursor = nil
        errorMessage = nil
        var modelPrompt = prompt
        if record.kind == .code, !isRemoteAgent, let workspace {
            let budget = { if case .apple = choice { return 6_000 } else { return 20_000 } }()
            modelPrompt = WorkspaceContext.block(workspace, pinned: record.pinnedPaths, prompt: prompt, budget: budget) + "\n\n" + prompt
        }
        if record.mode == .plan {
            modelPrompt = "[Plan mode: do not write final code or change anything yet. Read what you need, then give a short numbered plan and wait for the user to approve it.]\n" + modelPrompt
        }
        turns.append(.init(role: .user, text: prompt))
        if record.title == "New Chat" { record.title = String(prompt.prefix(48)) }
        isStreaming = true
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "reply") { }   // lets a cloud reply finish if you switch apps
        streamTask = Task {
            if !isHeadless { await Notifier.authorizeIfNeeded() }
            await refreshConnectorTools()
            await converse(modelPrompt)
            isStreaming = false
            persist()
            if let reply = turns.last(where: { $0.role == .assistant && !$0.text.isEmpty }), !Task.isCancelled {
                if !isHeadless { Notifier.post(researchRun ? .research : .reply, title: record.title,
                              body: ToolProtocol.stripCall(from: reply.text), chatID: id) }
            }
            researchRun = false
            stepLimit = Self.maxToolSteps
            if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
        }
    }

    /// One user message may trigger several model calls: reply, tool, reply, tool, …
    private func converse(_ firstPrompt: String) async {
        var nextPrompt = firstPrompt
        var steps = 0
        while !Task.isCancelled {
            guard let provider else { return }
            turns.append(.init(role: .assistant, text: ""))
            let index = turns.count - 1
            let history = Array(turns.dropLast(2))
            let started = Date()
            let sampling = record.sampling
            var log = RequestRecord(date: started, model: choice.label, system: Personalization.load().instructions(kind: record.kind, extra: extraInstructions),
                                    prompt: nextPrompt, historyTurns: history.count, sampling: sampling, toolCount: availableTools.count)
            do {
                for try await text in provider.stream(prompt: nextPrompt, history: history, kind: record.kind, extraInstructions: extraInstructions, sampling: sampling) {
                    if log.firstTokenSeconds == nil { log.firstTokenSeconds = Date().timeIntervalSince(started) }
                    let (clipped, stopped) = sampling.applyStops(text)
                    turns[index].text = clipped
                    let elapsed = Date().timeIntervalSince(started)
                    if elapsed > 0.5 { tokensPerSecond = Double(clipped.count) / 4 / elapsed }
                    if stopped { break }      // leaving the loop cancels generation
                }
                log.totalSeconds = Date().timeIntervalSince(started)
                log.reply = turns[index].text
                requests.append(log)
                if requests.count > 30 { requests.removeFirst() }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
                if turns[index].text.isEmpty { turns.remove(at: index) }
                return
            }
            guard !availableTools.isEmpty, let call = ToolProtocol.parse(turns[index].text) else {
                // Structured output: check the reply against the schema and ask the model to fix it (up to twice).
                if let problem = schemaProblem(in: turns[index].text), schemaRetries < 2 {
                    schemaRetries += 1
                    var note = ChatTurn(role: .tool, text: problem, toolName: "schema check", toolStatus: .failed)
                    note.text = problem
                    turns.append(note)
                    nextPrompt = "Your reply did not match the required JSON schema: \(problem)\nReply again with only the corrected JSON."
                    continue
                }
                schemaRetries = 0
                return
            }
            steps += 1
            guard steps <= stepLimit else {
                errorMessage = "Stopped after \(stepLimit) tool steps. Send a message to continue."
                return
            }
            let result = await runTool(call)
            nextPrompt = "Tool result (\(call.name)):\n\(result)"
            if Task.isCancelled { return }
        }
    }

    /// Runs one tool call (after approval if needed) and records it as a tool turn. Returns the text for the model.
    private func runTool(_ call: ParsedToolCall) async -> String {
        var turn = ChatTurn(role: .tool, text: "", toolName: call.name, toolArgs: call.raw, toolStatus: .pending)
        turns.append(turn)
        let index = turns.count - 1
        func finish(_ rawText: String, _ status: ToolStatus, change: FileChange? = nil) -> String {
            let text = Redactor.clean(rawText)
            turn.text = text; turn.toolStatus = status
            turn.changeScope = change?.scope; turn.changePath = change?.path; turn.changeBefore = change?.before; turn.changeAfter = change?.after
            turns[index] = turn
            return text
        }
        guard let tool = availableTools.first(where: { $0.spec.name == call.name }) else {
            return finish("Unknown tool '\(call.name)'. Available: \(availableTools.map(\.spec.name).joined(separator: ", ")).", .failed)
        }
        let context = toolContext
        let risk = call.name == "fetch_url" ? FetchURLTool.risk(for: call.arguments) : tool.spec.risk

        if record.mode == .plan, risk != .read {
            return finish("Plan mode is on, so this was not run. Describe the change in your plan instead.", .denied)
        }
        if risk == .network, context.networkMode == .off { return finish("Network access is off for this session.", .denied) }

        let preview = tool.preview(call.arguments, context: context)
        let untrustedSource = ["fetch_url", "web_search", "ssh_run", "sftp_read", "get_pull_request", "list_issues", "get_failed_job_logs"].contains(call.name) || call.name.hasPrefix("mcp_")
        let needsApproval: Bool = {
            // After reading outside content, "always allow" and auto-accept no longer apply to anything that changes something.
            if tainted, [.write, .execute, .networkWrite, .remote].contains(risk) { return true }
            if alwaysAllowed.contains(call.name) { return false }
            switch risk {
            case .read: return false
            case .write, .execute: return record.mode != .autoEdit
            case .network: return context.networkMode == .ask
            case .networkWrite, .remote: return true
            }
        }()
        if needsApproval {
            let decision = await requestApproval(.init(toolName: call.name, summary: tool.describe(call.arguments), risk: risk, change: preview, tainted: tainted))
            if decision == .deny { return finish("The user declined this action.", .denied) }
            if decision == .allowAlways { alwaysAllowed.insert(call.name) }
        }
        turns[index].toolStatus = .running
        turn.toolStatus = .running
        do {
            let output = try await tool.run(call.arguments, context: context)
            if untrustedSource { tainted = true }
            if risk == .remote { Notifier.post(.project, title: record.title, body: output.text, chatID: id) }
            return finish(output.text, .done, change: output.change)
        } catch {
            return finish("Error: \(error.localizedDescription)", .failed)
        }
    }

    /// Restores a file to how it was before a tool edited it.
    func undo(turnID: UUID) {
        guard let index = turns.firstIndex(where: { $0.id == turnID }), let path = turns[index].changePath else { return }
        let root = turns[index].changeScope == "documents" ? FilesFolder.root : workspace?.folderURL
        guard let url = try? WorkspacePath.resolve(path, root: root) else { return }
        let current = try? String(contentsOf: url, encoding: .utf8)
        guard current == turns[index].changeAfter else { errorMessage = "\(path) changed since this edit, so it wasn't undone."; return }
        do {
            if let before = turns[index].changeBefore { try before.write(to: url, atomically: true, encoding: .utf8) }
            else { try FileManager.default.removeItem(at: url) }   // the edit created this file
            turns[index].toolStatus = .undone
            persist()
        } catch { errorMessage = error.localizedDescription }
    }

    // MARK: Compaction

    /// Summarises everything but the last few turns into one note, freeing context.
    func compact() {
        guard !isStreaming, turns.count > 6, let provider else { return }
        let older = Array(turns.dropLast(4))
        let recent = Array(turns.suffix(4))
        isStreaming = true
        streamTask = Task {
            var summary = ""
            do {
                let ask = "Summarise the conversation so far in under 250 words. Keep file names, decisions, open problems and the user's goals. Output only the summary."
                for try await text in provider.stream(prompt: ask, history: older, kind: record.kind, extraInstructions: "", sampling: SamplingSettings()) { summary = text }
            } catch { errorMessage = "Couldn't compact: \(error.localizedDescription)"; isStreaming = false; return }
            var note = ChatTurn(role: .assistant, text: summary)
            note.isSummary = true
            turns = [note] + recent
            self.provider = Self.makeProvider(for: choice)    // fresh cache that matches the shorter history
            isStreaming = false
            persist()
        }
    }

    func regenerate() {
        guard !isStreaming, let index = turns.lastIndex(where: { $0.role == .user }) else { return }
        let text = turns[index].text
        turns.removeSubrange(index...)
        send(text)
    }

    func stop() { streamTask?.cancel() }

    // MARK: Claude Code-style keyboard behaviour

    /// Esc: interrupt a running reply; otherwise clear the input; a quick second Esc rewinds the last exchange.
    func escape() {
        if isStreaming { stop(); return }
        if Date().timeIntervalSince(lastEscape) < 0.6 { rewind(); lastEscape = .distantPast; return }
        lastEscape = Date()
        if !input.isEmpty { input = ""; historyCursor = nil }
    }

    /// Ctrl-C: interrupt, or clear the input.
    func interrupt() { if isStreaming { stop() } else { input = ""; historyCursor = nil } }

    /// Removes the last exchange and puts your prompt back in the box to edit.
    func rewind() {
        guard !isStreaming, let index = turns.lastIndex(where: { $0.role == .user }) else { return }
        input = turns[index].text
        turns.removeSubrange(index...)
        persist()
    }

    func historyPrevious() {
        let history = promptHistory
        guard !history.isEmpty else { return }
        let next = min((historyCursor ?? -1) + 1, history.count - 1)
        historyCursor = next
        input = history[history.count - 1 - next]
    }

    func historyNext() {
        guard let cursor = historyCursor else { return }
        if cursor == 0 { historyCursor = nil; input = ""; return }
        historyCursor = cursor - 1
        input = promptHistory[promptHistory.count - cursor]
    }

    func cycleMode() { mode = mode.next }

    func cycleModel() {
        var options: [ProviderChoice] = AppleModelKind.allCases.map { .apple($0) }
        options += CuratedModels.everything.filter { ModelManager.shared.isDownloaded($0.id) }.map { .mlx($0.id) }
        guard let index = options.firstIndex(of: choice) else { return }
        select(options[(index + 1) % options.count])
    }

    func clearConversation() {
        stop()
        turns = []
        provider = Self.makeProvider(for: choice)   // fresh KV cache
        persist()
    }

    static let slashCommands: [(name: String, help: String)] = [
        ("/clear", "Clear this conversation"), ("/plan", "Toggle plan mode"), ("/model", "Switch to the next model"),
        ("/repo", "Attach a GitHub repo (code sessions)"), ("/compact", "Summarise older messages to free context"),
        ("/research", "Research a topic on the web and write a report"), ("/fixci", "Diagnose the latest failed CI run and propose a fix"),
        ("/review", "Review a pull request by number"), ("/help", "Show keyboard shortcuts"),
    ]

    private func handleSlash(_ text: String) -> Bool {
        if text.lowercased().hasPrefix("/fixci") {
            send("Check why CI is failing: call list_workflow_runs, then get_failed_job_logs for the newest failed run. Explain the cause in two sentences. Then create a branch with git_branch, fix it with edit_file, commit and push with git_commit_push, and open a pull request.")
            return true
        }
        if text.lowercased().hasPrefix("/review") {
            let number = text.dropFirst("/review".count).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
            guard Int(number) != nil else { errorMessage = "Add a pull request number, like /review 12."; return true }
            send("Review pull request #\(number): call get_pull_request, then list the bugs, risks and missing tests with file names. Do not submit the review; show me your findings first.")
            return true
        }
        if text.lowercased().hasPrefix("/research") {
            let topic = text.dropFirst("/research".count).trimmingCharacters(in: .whitespaces)
            guard !topic.isEmpty else { errorMessage = "Add a topic, like /research the history of the ukulele."; return true }
            researchRun = true
            stepLimit = 20
            send("Research this thoroughly using web_search and fetch_url: \(topic)\nRun several searches, open the best sources, then write a report with headings and a Sources list with links.")
            return true
        }
        switch text.lowercased().split(separator: " ").first.map(String.init) {
        case "/clear": clearConversation()
        case "/plan": mode = mode == .plan ? .ask : .plan
        case "/model": cycleModel()
        case "/repo": showRepoPicker = true
        case "/compact": compact()
        case "/help": showHelp = true
        default: return false
        }
        return true
    }

    func attach(_ workspace: WorkspaceRecord?) {
        self.workspace = workspace
        record.workspaceID = workspace?.id
        if workspace == nil { record.pinnedPaths = [] }
        save()
    }

    func togglePinned(_ path: String) {
        var pinned = record.pinnedPaths
        if let i = pinned.firstIndex(of: path) { pinned.remove(at: i) } else { pinned.append(path) }
        record.pinnedPaths = pinned
        save()
    }

    private func persist() {
        record.turns = turns
        record.updatedAt = .now
        save()
        ChatIndexer.update(record)
    }
}
