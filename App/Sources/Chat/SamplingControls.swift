import SwiftUI

/// Temperature, top-p, top-k, min-p, repeat penalty, seed, max tokens and stop sequences for one chat.
struct SamplingControls: View {
    let model: ChatViewModel

    private func binding<T>(_ keyPath: WritableKeyPath<SamplingSettings, T>) -> Binding<T> {
        Binding(get: { model.record.sampling[keyPath: keyPath] }, set: { var s = model.record.sampling; s[keyPath: keyPath] = $0; model.record.sampling = s })
    }

    private func optionalSlider(_ title: String, _ keyPath: WritableKeyPath<SamplingSettings, Double?>, range: ClosedRange<Double>, step: Double, fallback: Double) -> some View {
        VStack(alignment: .leading) {
            Toggle(title, isOn: Binding(get: { model.record.sampling[keyPath: keyPath] != nil },
                                        set: { var s = model.record.sampling; s[keyPath: keyPath] = $0 ? fallback : nil; model.record.sampling = s }))
            if let value = model.record.sampling[keyPath: keyPath] {
                Slider(value: Binding(get: { value }, set: { var s = model.record.sampling; s[keyPath: keyPath] = $0; model.record.sampling = s }), in: range, step: step)
                Text(value.formatted(.number.precision(.fractionLength(2)))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private func optionalInt(_ title: String, _ keyPath: WritableKeyPath<SamplingSettings, Int?>) -> some View {
        TextField(title, value: binding(keyPath), format: .number).keyboardType(.numberPad)
    }

    var body: some View {
        optionalSlider("Temperature", \.temperature, range: 0...2, step: 0.05, fallback: 0.7)
        optionalSlider("Top-p", \.topP, range: 0.05...1, step: 0.05, fallback: 0.95)
        optionalSlider("Min-p", \.minP, range: 0...0.5, step: 0.01, fallback: 0.05)
        optionalSlider("Repeat penalty", \.repeatPenalty, range: 1...2, step: 0.05, fallback: 1.1)
        optionalInt("Top-k", \.topK)
        optionalInt("Seed (for repeatable output)", \.seed)
        optionalInt("Max tokens", \.maxTokens)
        TextField("Stop sequences, comma separated", text: Binding(
            get: { model.record.sampling.stop.joined(separator: ", ") },
            set: { var s = model.record.sampling; s.stop = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }; model.record.sampling = s }))
            .textInputAutocapitalization(.never).autocorrectionDisabled()
        if !model.record.sampling.isDefault { Button("Reset to model defaults", role: .destructive) { model.record.sampling = SamplingSettings() } }
    }
}
