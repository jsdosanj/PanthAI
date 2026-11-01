import Accelerate
import Foundation
import NaturalLanguage

/// Meaning-based vectors from the sentence model built into iPadOS. Nothing is downloaded and nothing leaves the device.
/// Where the model isn't available, search falls back to keyword matching alone.
enum Embedder {
    nonisolated(unsafe) private static let model = NLEmbedding.sentenceEmbedding(for: .english)
    static var available: Bool { model != nil }

    /// Unit-length vector, or nil when the model is unavailable. Call from one place at a time (the index actor does).
    static func vector(_ text: String) -> [Float]? {
        guard let model, let raw = model.vector(for: String(text.prefix(1500))) else { return nil }
        var v = raw.map { Float($0) }
        let norm = sqrt(vDSP.sumOfSquares(v))
        guard norm > 0 else { return nil }
        v = vDSP.divide(v, norm)
        return v
    }

    static func data(_ v: [Float]) -> Data { v.withUnsafeBufferPointer { Data(buffer: $0) } }

    static func floats(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

enum Tokens {
    private static let stop: Set<String> = ["the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "had", "her", "was", "one", "our",
                                            "out", "has", "have", "that", "with", "this", "from", "they", "will", "what", "when", "your", "which", "their", "there", "been", "were", "about"]
    static func of(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 1 && !stop.contains($0) }
    }
}
