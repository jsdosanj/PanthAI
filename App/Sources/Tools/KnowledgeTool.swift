import Foundation

/// Lets the model look things up in the documents and photos the user added to Knowledge.
struct SearchKnowledgeTool: AgentTool {
    let spec = ToolSpec(name: "search_knowledge",
                        summary: "Search the user's own documents, notes and photos (their Knowledge) and return the best-matching excerpts with their sources.",
                        parameters: "query: string, limit?: number", risk: .read)

    func run(_ args: [String: JSONValue], context: ToolContext) async throws -> ToolOutput {
        guard let query = args["query"]?.string, !query.isEmpty else { throw ToolError("query is required") }
        let limit = min(max(args["limit"]?.int ?? 5, 1), 10)
        let hits = await KnowledgeIndex.shared.search(query, limit: limit)
        guard !hits.isEmpty else { return ToolOutput(text: "Nothing in Knowledge matches that. Try different words.") }
        return ToolOutput(text: KnowledgeContext.format(hits, budget: 8_000))
    }
}
