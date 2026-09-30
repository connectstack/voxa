import SwiftUI
import VoxaCore

/// The "Safety" tab: whether Voxa acts without asking, how eagerly it asks otherwise, and the limits on one command.
struct SafetySettingsView: View {
    @Bindable var store: SettingsStore
    @State private var model: SafetyModel

    init(store: SettingsStore) {
        self.store = store
        _model = State(initialValue: SafetyModel(store: store))
    }

    var body: some View {
        Form {
            Section(L10n.FullControl.section) {
                Toggle(
                    L10n.FullControl.toggle,
                    isOn: Binding(get: { model.fullControl }, set: { model.setFullControl($0) })
                )
                Text(model.fullControl ? L10n.FullControl.helpOn : L10n.FullControl.helpOff)
                    .font(.caption)
                    .foregroundStyle(model.fullControl ? Color.orange : Color.secondary)
            }
            Section {
                Picker(L10n.SettingsModel.strictness, selection: $store.current.confirmationStrictness) {
                    Text(L10n.SettingsModel.strictnessStandard).tag(ConfirmationStrictness.standard)
                    Text(L10n.SettingsModel.strictnessStrict).tag(ConfirmationStrictness.strict)
                    Text(L10n.SettingsModel.strictnessParanoid).tag(ConfirmationStrictness.paranoid)
                }
                .disabled(model.fullControl)
                Text(model.fullControl ? L10n.FullControl.strictnessUnused : L10n.SettingsModel.strictnessHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle(L10n.CompletionCheck.toggle, isOn: $store.current.verifyCompletion)
                Text(L10n.CompletionCheck.help).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Stepper(value: $store.current.followUpWindowSeconds, in: 0...600, step: 30) {
                    Text(L10n.SettingsModel.followUp(store.current.followUpWindowSeconds))
                }
                Text(L10n.SettingsModel.followUpHelp).font(.caption).foregroundStyle(.secondary)
                Stepper(value: $store.current.maxAgentSteps, in: AppSettings.maxAgentStepsRange) {
                    Text(L10n.SettingsModel.maxSteps(store.current.maxAgentSteps))
                }
            }
        }
        .formStyle(.grouped)
        .fullControlQuestion(
            isPresented: $model.isAsking,
            give: { model.giveFullControl() },
            keepAsking: { model.keepAsking() }
        )
    }
}

extension View {
    /// The question asked before full control turns on.
    ///
    /// Neither button is the default one: Return does nothing, Esc is "Keep Asking", and "Give Full Control" takes a deliberate
    /// click, so pressing Return by habit can never turn it on. (A test presents this in a real window and checks it.)
    func fullControlQuestion(
        isPresented: Binding<Bool>,
        give: @escaping () -> Void,
        keepAsking: @escaping () -> Void
    ) -> some View {
        alert(L10n.FullControl.confirmTitle, isPresented: isPresented) {
            Button(L10n.FullControl.confirmKeepAsking, role: .cancel, action: keepAsking)
            Button(L10n.FullControl.confirmGive, role: .destructive, action: give)
        } message: {
            Text(L10n.FullControl.confirmMessage)
        }
    }
}
