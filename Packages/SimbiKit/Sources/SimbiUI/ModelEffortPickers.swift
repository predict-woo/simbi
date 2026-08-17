import CodexKit
import SimbiKit
import SwiftUI

/// One agent role's model + effort picker pair, shared by Settings and
/// onboarding so the semantics can't diverge: effort options follow the
/// row's chosen model, and a saved override missing from the live list
/// stays selectable instead of silently disappearing.
struct ModelEffortPickers: View {
    @Binding var choice: ModelChoice
    let models: [CodexModels.Model]

    var body: some View {
        HStack(spacing: 8) {
            modelPicker
            effortPicker
        }
    }

    private var modelPicker: some View {
        Picker("Model", selection: $choice.model) {
            Text("Default").tag(String?.none)
            ForEach(stalePreserving(choice.model, in: models.map(\.id)), id: \.self) { model in
                Text(model).tag(String?.some(model))
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    /// Efforts of the row's model ("Default" model = the server's default
    /// model), so the options track the picker beside this one.
    private var effortPicker: some View {
        let efforts = CodexModels.efforts(for: choice.model, in: models)
        return Picker("Effort", selection: $choice.effort) {
            Text("Default").tag(String?.none)
            ForEach(stalePreserving(choice.effort, in: efforts.map(\.id)), id: \.self) { effort in
                Text(effort).tag(String?.some(effort))
            }
        }
        .labelsHidden()
        .fixedSize()
        .help(
            efforts.first(where: { $0.id == choice.effort })?.description
                ?? "Reasoning effort. Default uses the model's own default.")
    }

    /// Keep a saved override selectable even if the list is stale.
    private func stalePreserving(_ saved: String?, in options: [String]) -> [String] {
        guard let saved, !options.contains(saved) else { return options }
        return [saved] + options
    }
}
