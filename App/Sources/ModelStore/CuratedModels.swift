import Foundation

enum ModelCapability: String, Sendable, CaseIterable {
    case ocr = "OCR & vision"
    case translation = "Translation"
    case coding = "Coding"
    case design = "Graphic design"
    case general = "General"
}

struct CuratedModel: Identifiable, Sendable {
    let family: String
    let id: String            // Hugging Face repo id (mlx-community)
    let name: String
    let weightsGB: Double     // verified against the Hub file sizes, 2026-10-31
    let capabilities: [ModelCapability]
    let license: String       // shown before download; the user accepts it with the download
    /// false while mlx-swift-lm can't run this architecture yet.
    let runtimeReady: Bool
    let note: String
    /// Set for models imported from the Files app; they load from this folder instead of Hugging Face.
    var localPath: String? = nil

    /// Uses the memory actually seen on this iPad when we have it, otherwise an estimate.
    var compatibility: Compatibility {
        if let seen = MeasuredFootprints.value(id) { return CompatibilityEstimator.rate(measuredGB: seen) }
        return CompatibilityEstimator.rate(weightsGB: weightsGB)
    }
}

/// MLX 4-bit (or lower) models the user can download. Apple Foundation Models
/// are built in and are not listed here (nothing to download).
enum CuratedModels {
    static let all: [CuratedModel] = [
        .init(family: "Qwen 3", id: "mlx-community/Qwen3-VL-4B-Instruct-4bit", name: "Qwen3-VL 4B", weightsGB: 3.11,
              capabilities: [.ocr, .design, .translation], license: "Apache-2.0", runtimeReady: true,
              note: "Reads images, screenshots and documents; critiques layouts."),
        .init(family: "Qwen 3", id: "mlx-community/Qwen3-VL-8B-Instruct-4bit", name: "Qwen3-VL 8B", weightsGB: 5.78,
              capabilities: [.ocr, .design, .translation], license: "Apache-2.0", runtimeReady: true,
              note: "Best vision quality; wants a 16 GB iPad."),
        .init(family: "Qwen 3", id: "mlx-community/Qwen3-1.7B-4bit", name: "Qwen3 1.7B", weightsGB: 0.98,
              capabilities: [.translation, .general], license: "Apache-2.0", runtimeReady: true,
              note: "Tiny and fast on any M-series iPad."),
        .init(family: "Qwen 3", id: "mlx-community/Qwen3-4B-4bit", name: "Qwen3 4B", weightsGB: 2.28,
              capabilities: [.translation, .general], license: "Apache-2.0", runtimeReady: true,
              note: "Strong multilingual translation for its size."),
        .init(family: "Qwen 3", id: "mlx-community/Qwen3-8B-4bit", name: "Qwen3 8B", weightsGB: 4.62,
              capabilities: [.translation, .general, .design], license: "Apache-2.0", runtimeReady: true,
              note: "Higher-quality writing, SVG and HTML/CSS."),
        .init(family: "Qwen 3.5", id: "mlx-community/Qwen3.5-2B-MLX-4bit", name: "Qwen3.5 2B", weightsGB: 1.75,
              capabilities: [.general, .translation], license: "Apache-2.0", runtimeReady: true,
              note: "Newest Qwen, small and quick."),
        .init(family: "Qwen 3.5", id: "mlx-community/Qwen3.5-4B-MLX-4bit", name: "Qwen3.5 4B", weightsGB: 3.06,
              capabilities: [.general, .translation, .coding], license: "Apache-2.0", runtimeReady: true,
              note: "Great all-rounder."),
        .init(family: "Qwen 3.5", id: "mlx-community/Qwen3.5-9B-MLX-4bit", name: "Qwen3.5 9B", weightsGB: 5.98,
              capabilities: [.general, .coding, .ocr, .design], license: "Apache-2.0", runtimeReady: true,
              note: "Vision-capable; best on 16 GB iPads."),
        .init(family: "Qwen Coder", id: "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit", name: "Qwen2.5 Coder 1.5B", weightsGB: 0.88,
              capabilities: [.coding], license: "Apache-2.0", runtimeReady: true,
              note: "Instant completions and command suggestions."),
        .init(family: "Qwen Coder", id: "mlx-community/Qwen2.5-Coder-3B-Instruct-4bit", name: "Qwen2.5 Coder 3B", weightsGB: 1.75,
              capabilities: [.coding], license: "Qwen Research", runtimeReady: true,
              note: "Good balance for editing repos on the go."),
        .init(family: "Qwen Coder", id: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit", name: "Qwen2.5 Coder 7B", weightsGB: 4.3,
              capabilities: [.coding, .design], license: "Apache-2.0", runtimeReady: true,
              note: "Best coding quality that fits most iPads."),
        .init(family: "Gemma 4", id: "mlx-community/gemma-4-e2b-it-4bit", name: "Gemma 4 E2B", weightsGB: 3.58,
              capabilities: [.general, .translation, .ocr], license: "Gemma terms", runtimeReady: true,
              note: "Google's newest small multimodal model."),
        .init(family: "Gemma 4", id: "mlx-community/gemma-4-e4b-it-4bit", name: "Gemma 4 E4B", weightsGB: 5.18,
              capabilities: [.general, .translation, .ocr, .design], license: "Gemma terms", runtimeReady: true,
              note: "Stronger multimodal Gemma."),
        .init(family: "Gemma 3", id: "mlx-community/gemma-3-1b-it-qat-4bit", name: "Gemma 3 1B", weightsGB: 0.77,
              capabilities: [.general, .translation], license: "Gemma terms", runtimeReady: true,
              note: "Smallest Gemma."),
        .init(family: "Gemma 3", id: "mlx-community/gemma-3-4b-it-qat-4bit", name: "Gemma 3 4B", weightsGB: 3.03,
              capabilities: [.general, .translation, .ocr], license: "Gemma terms", runtimeReady: true,
              note: "Quantization-aware, good quality and vision."),
        .init(family: "Gemma 3", id: "mlx-community/gemma-3-12b-it-qat-4bit", name: "Gemma 3 12B", weightsGB: 8.07,
              capabilities: [.general, .translation, .ocr, .design], license: "Gemma terms", runtimeReady: true,
              note: "Large; 16 GB iPads only."),
        .init(family: "LFM 2.5", id: "mlx-community/LFM2.5-1.2B-Instruct-4bit", name: "LFM2.5 1.2B", weightsGB: 0.66,
              capabilities: [.general, .translation], license: "LFM Open License", runtimeReady: true,
              note: "Liquid AI; very fast, tiny memory."),
        .init(family: "LFM 2.5", id: "mlx-community/LFM2.5-2.6B-4bit", name: "LFM2.5 2.6B", weightsGB: 1.54,
              capabilities: [.general, .translation], license: "LFM Open License", runtimeReady: true,
              note: "Fast decode with strong tool calling."),
        .init(family: "LFM 2.5", id: "mlx-community/LFM2.5-VL-1.6B-4bit", name: "LFM2.5-VL 1.6B", weightsGB: 1.5,
              capabilities: [.ocr, .general], license: "LFM Open License", runtimeReady: true,
              note: "Small vision model for OCR."),
        .init(family: "MiniCPM 5", id: "mlx-community/MiniCPM5-1B-OptiQ-4bit", name: "MiniCPM5 1B", weightsGB: 0.92,
              capabilities: [.general, .translation], license: "Apache-2.0", runtimeReady: true,
              note: "Efficient edge model."),
        .init(family: "MiniCPM 5", id: "mlx-community/MiniCPM5-2B-mlx-4Bit", name: "MiniCPM5 2B", weightsGB: 1.43,
              capabilities: [.general, .translation], license: "Apache-2.0", runtimeReady: true,
              note: "Strong quality for 2B."),
        .init(family: "Ministral 3", id: "mlx-community/Ministral-3-3B-Instruct-2512-4bit", name: "Ministral 3 3B", weightsGB: 2.78,
              capabilities: [.general, .translation, .ocr], license: "Apache-2.0", runtimeReady: true,
              note: "Mistral's small multimodal model; good multilingual."),
        .init(family: "Ministral 3", id: "mlx-community/Ministral-3-8B-Instruct-2512-4bit", name: "Ministral 3 8B", weightsGB: 5.63,
              capabilities: [.general, .translation, .ocr], license: "Apache-2.0", runtimeReady: true,
              note: "Higher quality; 16 GB iPads."),
        .init(family: "Granite 4.0", id: "mlx-community/granite-4.0-h-micro-4bit", name: "Granite 4.0 H Micro", weightsGB: 1.81,
              capabilities: [.general, .coding], license: "Apache-2.0", runtimeReady: true,
              note: "IBM; hybrid Mamba, efficient on long context."),
        .init(family: "Granite 4.0", id: "mlx-community/granite-4.0-h-tiny-4bit", name: "Granite 4.0 H Tiny", weightsGB: 3.92,
              capabilities: [.general, .coding], license: "Apache-2.0", runtimeReady: true,
              note: "IBM mixture-of-experts."),
        .init(family: "DeepSeek R1", id: "mlx-community/DeepSeek-R1-Distill-Qwen-1.5B-4bit", name: "DeepSeek R1 Distill 1.5B", weightsGB: 1.01,
              capabilities: [.general, .coding], license: "MIT", runtimeReady: true,
              note: "Shows its reasoning. Small."),
        .init(family: "DeepSeek R1", id: "mlx-community/DeepSeek-R1-Distill-Qwen-7B-4bit", name: "DeepSeek R1 Distill 7B", weightsGB: 4.3,
              capabilities: [.general, .coding], license: "MIT", runtimeReady: true,
              note: "Step-by-step reasoning for math and code."),
        .init(family: "Cogito v1", id: "mlx-community/deepcogito-cogito-v1-preview-llama-3B-4bit", name: "Cogito v1 3B", weightsGB: 1.82,
              capabilities: [.general, .coding], license: "Llama 3.2 Community", runtimeReady: true,
              note: "Hybrid reasoning (preview)."),
        .init(family: "Cogito v1", id: "mlx-community/deepcogito-cogito-v1-preview-llama-8B-4bit", name: "Cogito v1 8B", weightsGB: 4.53,
              capabilities: [.general, .coding], license: "Llama 3.1 Community", runtimeReady: true,
              note: "Hybrid reasoning (preview)."),
    ]

    /// Curated list plus models the user added by Hugging Face ID or from Files.
    static var everything: [CuratedModel] { all + CustomModels.load() }

    static func find(_ id: String) -> CuratedModel? { everything.first { $0.id == id } }

    /// Families in display order.
    static var families: [String] {
        var seen = Set<String>()
        return everything.compactMap { seen.insert($0.family).inserted ? $0.family : nil }
    }

    /// Models that fit this iPad.
    static func recommended(for device: DeviceProfile = .current) -> [CuratedModel] {
        everything.filter { $0.runtimeReady && CompatibilityEstimator.rate(weightsGB: $0.weightsGB, on: device) != .wontFit }
    }
}
