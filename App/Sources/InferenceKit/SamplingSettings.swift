import Foundation

/// Per-chat generation controls. nil means "use the model's default".
struct SamplingSettings: Codable, Sendable, Equatable {
    var temperature: Double?
    var topP: Double?
    var topK: Int?
    var minP: Double?
    var repeatPenalty: Double?
    var seed: Int?
    var maxTokens: Int?
    var stop: [String] = []

    var isDefault: Bool { self == SamplingSettings() }

    /// Cuts the text at the first stop sequence. Returns the text and whether a stop was hit.
    func applyStops(_ text: String) -> (String, Bool) {
        var cut: String.Index?
        for s in stop where !s.isEmpty {
            if let r = text.range(of: s), cut == nil || r.lowerBound < cut! { cut = r.lowerBound }
        }
        guard let cut else { return (text, false) }
        return (String(text[..<cut]), true)
    }
}

/// A small JSON Schema checker (type, required, properties, items, enum) for structured output.
enum SchemaValidator {
    static func validate(_ value: JSONValue, against schema: JSONValue, path: String = "$") -> String? {
        if let allowed = schema["enum"]?.array, !allowed.contains(value) { return "\(path) must be one of \(allowed.map(\.compactString).joined(separator: ", "))" }
        switch schema["type"]?.string {
        case "object":
            guard let object = value.object else { return "\(path) must be an object" }
            for key in (schema["required"]?.array ?? []).compactMap(\.string) where object[key] == nil { return "\(path).\(key) is required" }
            for (key, sub) in schema["properties"]?.object ?? [:] {
                if let child = object[key], let error = validate(child, against: sub, path: "\(path).\(key)") { return error }
            }
        case "array":
            guard let array = value.array else { return "\(path) must be an array" }
            if let item = schema["items"] {
                for (i, child) in array.enumerated() { if let error = validate(child, against: item, path: "\(path)[\(i)]") { return error } }
            }
        case "string": if value.string == nil { return "\(path) must be a string" }
        case "number", "integer": if case .number = value {} else { return "\(path) must be a number" }
        case "boolean": if value.bool == nil { return "\(path) must be true or false" }
        default: break
        }
        return nil
    }

    /// Pulls the first JSON object or array out of a reply (plain or in a code fence).
    static func extractJSON(from text: String) -> JSONValue? {
        if let fence = text.range(of: #"```(?:json)?\s*\n([\s\S]*?)\n```"#, options: .regularExpression) {
            let inner = String(text[fence]).replacingOccurrences(of: #"^```(?:json)?\s*\n|\n```$"#, with: "", options: .regularExpression)
            if let json = JSONValue.parse(inner) { return json }
        }
        if let json = JSONValue.parse(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return json }
        guard let start = text.firstIndex(where: { $0 == "{" || $0 == "[" }), let end = text.lastIndex(where: { $0 == "}" || $0 == "]" }), start < end else { return nil }
        return JSONValue.parse(String(text[start...end]))
    }
}
