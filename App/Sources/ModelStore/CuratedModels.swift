import Foundation

enum ModelCapability: String, Sendable, CaseIterable {
    case ocr = "OCR & vision"
    case translation = "Translation"
    case coding = "Coding"
    case design = "Graphic design"
    case general = "General"
}

struct CuratedModel: Identifiable, Sendable {
    let id: String            // Hugging Face repo id (mlx-community)
    let name: String
    let weightsGB: Double     // verified against the Hub file sizes, 2026-10-31
    let capabilities: [ModelCapability]
    let note: String

    var compatibility: Compatibility { CompatibilityEstimator.rate(weightsGB: weightsGB) }
}

/// Hand-picked, Apache-2.0 MLX 4-bit models. Apple Foundation Models is the
/// built-in default and is not listed here (nothing to download).
enum CuratedModels {
    static let all: [CuratedModel] = [
        .init(id: "mlx-community/Qwen3-VL-4B-Instruct-4bit", name: "Qwen3-VL 4B", weightsGB: 3.11,
              capabilities: [.ocr, .design, .translation], note: "Reads images, screenshots and documents; critiques layouts."),
        .init(id: "mlx-community/Qwen3-VL-8B-Instruct-4bit", name: "Qwen3-VL 8B", weightsGB: 5.78,
              capabilities: [.ocr, .design, .translation], note: "Best vision quality; wants a 16 GB iPad."),
        .init(id: "mlx-community/Qwen3-1.7B-4bit", name: "Qwen3 1.7B", weightsGB: 0.98,
              capabilities: [.translation, .general], note: "Tiny and fast; fine on any M-series iPad."),
        .init(id: "mlx-community/Qwen3-4B-4bit", name: "Qwen3 4B", weightsGB: 2.28,
              capabilities: [.translation, .general], note: "Strong multilingual translation for its size."),
        .init(id: "mlx-community/Qwen3-8B-4bit", name: "Qwen3 8B", weightsGB: 4.62,
              capabilities: [.translation, .general, .design], note: "Higher quality writing, SVG and HTML/CSS."),
        .init(id: "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit", name: "Qwen2.5 Coder 1.5B", weightsGB: 0.88,
              capabilities: [.coding], note: "Instant completions and command suggestions."),
        .init(id: "mlx-community/Qwen2.5-Coder-3B-Instruct-4bit", name: "Qwen2.5 Coder 3B", weightsGB: 1.75,
              capabilities: [.coding], note: "Good balance for editing repos on the go."),
        .init(id: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit", name: "Qwen2.5 Coder 7B", weightsGB: 4.3,
              capabilities: [.coding, .design], note: "Best coding quality that fits most iPads."),
    ]

    /// Models that fit this iPad, best-fitting first within each capability.
    static func recommended(for device: DeviceProfile = .current) -> [CuratedModel] {
        all.filter { CompatibilityEstimator.rate(weightsGB: $0.weightsGB, on: device) != .wontFit }
    }
}
