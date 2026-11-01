import Foundation

/// A snapshot of a provider's settings that can cross into background work.
struct RemoteConfig: Sendable {
    let name: String
    let kind: RemoteKind
    let baseURL: String
    let apiKey: String?
    let model: String
}

struct RemoteError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Streams chat from OpenAI-compatible servers (OpenAI, LM Studio, Ollama, GitHub Models, OpenRouter)
/// and from Anthropic. Everything sent here leaves the iPad, so the UI labels these as cloud/network models.
struct RemoteProvider: ModelProvider {
    let config: RemoteConfig
    var displayName: String { config.model }

    private func endpoint(_ path: String) throws -> URL {
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: base + path) else { throw RemoteError(message: "Invalid server address.") }
        return url
    }

    func stream(prompt: String, history: [ChatTurn], kind: SessionKind, extraInstructions: String, sampling: SamplingSettings) -> AsyncThrowingStream<String, Error> {
        let system = Personalization.load().instructions(kind: kind, extra: extraInstructions)
        let trimmed = ContextBudget.trim(history, maxChars: 120_000)
        let messages: [(role: String, content: String)] =
            trimmed.filter { !$0.modelText.isEmpty }.map { ($0.role == .assistant ? "assistant" : "user", $0.modelText) } + [("user", prompt)]
        let config = config
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try buildRequest(system: system, messages: messages, sampling: sampling)
                    let (bytes, response) = try await AppNet.session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw RemoteError(message: "No response from \(config.name).") }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = ""
                        for try await line in bytes.lines { body += line; if body.count > 600 { break } }
                        throw RemoteError(message: "\(config.name) returned \(http.statusCode). \(Self.errorText(body))")
                    }
                    var text = ""
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let json = JSONValue.parse(payload) else { continue }
                        if json["type"]?.string == "error" || json["error"] != nil {
                            throw RemoteError(message: "\(config.name): \(json["error"]?["message"]?.string ?? json["error"]?.string ?? "the stream reported an error")")
                        }
                        guard let piece = Self.delta(from: json, kind: config.kind) else { continue }
                        text += piece
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func buildRequest(system: String, messages: [(role: String, content: String)], sampling: SamplingSettings) throws -> URLRequest {
        var request: URLRequest
        var body: [String: JSONValue]
        let chat = messages.map { JSONValue.object(["role": .string($0.role), "content": .string($0.content)]) }
        switch config.kind {
        case .openAICompatible:
            request = URLRequest(url: try endpoint("/chat/completions"))
            body = ["model": .string(config.model), "stream": .bool(true),
                    "messages": .array([.object(["role": .string("system"), "content": .string(system)])] + chat)]
        case .openAIResponses:
            request = URLRequest(url: try endpoint("/responses"))
            body = ["model": .string(config.model), "stream": .bool(true), "instructions": .string(system), "input": .array(chat)]
        case .anthropic:
            request = URLRequest(url: try endpoint("/v1/messages"))
            body = ["model": .string(config.model), "stream": .bool(true), "max_tokens": .number(8192),
                    "system": .string(system), "messages": .array(chat)]
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        if let v = sampling.temperature { body["temperature"] = .number(v) }
        if let v = sampling.topP { body[config.kind == .openAIResponses ? "top_p" : "top_p"] = .number(v) }
        if let v = sampling.maxTokens { body[config.kind == .openAICompatible ? "max_tokens" : (config.kind == .anthropic ? "max_tokens" : "max_output_tokens")] = .number(Double(v)) }
        if config.kind == .openAICompatible {
            if let v = sampling.seed { body["seed"] = .number(Double(v)) }
            if !sampling.stop.isEmpty { body["stop"] = .array(sampling.stop.prefix(4).map { .string($0) }) }
        }
        if config.kind == .anthropic {
            if let v = sampling.topK { body["top_k"] = .number(Double(v)) }
            if !sampling.stop.isEmpty { body["stop_sequences"] = .array(sampling.stop.prefix(4).map { .string($0) }) }
        }
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = config.apiKey, !key.isEmpty {
            if config.kind == .anthropic { request.setValue(key, forHTTPHeaderField: "x-api-key") }
            else { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        }
        request.httpBody = try JSONEncoder().encode(JSONValue.object(body))
        return request
    }

    private static func delta(from json: JSONValue, kind: RemoteKind) -> String? {
        switch kind {
        case .openAICompatible:
            return json["choices"]?.array?.first?["delta"]?["content"]?.string
        case .openAIResponses:
            return json["type"]?.string == "response.output_text.delta" ? json["delta"]?.string : nil
        case .anthropic:
            return json["type"]?.string == "content_block_delta" ? json["delta"]?["text"]?.string : nil
        }
    }

    private static func errorText(_ body: String) -> String {
        if let json = JSONValue.parse(body) {
            return json["error"]?["message"]?.string ?? json["error"]?.string ?? json["message"]?.string ?? ""
        }
        return String(body.prefix(200))
    }

    /// Lists the models the server offers, for the picker.
    static func fetchModels(kind: RemoteKind, baseURL: String, apiKey: String?) async throws -> [String] {
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: base + (kind == .anthropic ? "/v1/models" : "/models")) else { throw RemoteError(message: "Invalid server address.") }
        var request = URLRequest(url: url, timeoutInterval: 20)
        if let apiKey, !apiKey.isEmpty {
            if kind == .anthropic { request.setValue(apiKey, forHTTPHeaderField: "x-api-key"); request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
            else { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        }
        let (data, response) = try await AppNet.session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw RemoteError(message: "Couldn't list models. Check the address and key.")
        }
        let items = json["data"]?.array ?? json.array ?? []
        return items.compactMap { $0["id"]?.string }.sorted()
    }
}
