import AppKit
import KeyboardShortcuts
import SwiftUI
import VoxaCore
import VoxaSpeech
import VoxaVoice

/// The General tab: the shortcut, speech recognition, the voice Voxa answers in, and starting at login.
struct GeneralSettingsView: View {
    @Bindable var store: SettingsStore
    let services: SettingsServices

    @State private var languages: [SpeechLanguage] = []
    @State private var voices: [VoiceInfo] = []
    @State private var login: LaunchAtLoginModel
    @State private var siriSetup: SiriSetup

    init(store: SettingsStore, services: SettingsServices) {
        self.store = store
        self.services = services
        _login = State(initialValue: LaunchAtLoginModel(control: services.launchAtLogin))
        _siriSetup = State(initialValue: services.siri.setup())
    }

    var body: some View {
        Form {
            shortcutSection
            siriSection
            barSection
            speechSection
            voiceSection
            startupSection
        }
        .formStyle(.grouped)
        .task {
            // Building the list instantiates a recognizer per language, so keep it off the main thread.
            languages = await Task.detached { SpeechLanguages.available() }.value
        }
        .onAppear {
            voices = VoiceCatalog.sorted(services.voice.voices(), for: store.current.localeIdentifier)
            login.refresh()
            siriSetup = services.siri.setup()
        }
        // Siri is switched on in System Settings: what it says here follows when the person comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            siriSetup = services.siri.setup()
        }
    }

    // MARK: Sections

    private var shortcutSection: some View {
        Section {
            KeyboardShortcuts.Recorder(for: .pushToTalk) {
                Text(L10n.Settings.pushToTalk)
            }
            Text(L10n.Settings.pushToTalkHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var siriSection: some View {
        Section(L10n.Siri.section) {
            Text(L10n.Siri.help).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: siriIsReady ? "checkmark.circle.fill" : "info.circle")
                    .foregroundStyle(siriIsReady ? Color.green : Color.orange)
                    .accessibilityHidden(true)
                Text(siriStatus).font(.caption)
                Spacer()
                Button(L10n.Siri.openSettings) { services.siri.openSettings() }
            }
        }
    }

    private var siriIsReady: Bool { siriSetup.isEnabled && siriSetup.listensForHeySiri }

    private var siriStatus: String {
        if !siriSetup.isEnabled { return L10n.Siri.siriOff }
        return siriSetup.listensForHeySiri ? L10n.Siri.heySiriOn : L10n.Siri.heySiriOff
    }

    private var barSection: some View {
        Section(L10n.Bar.section) {
            KeyboardShortcuts.Recorder(for: .openBar) {
                Text(L10n.Bar.shortcut)
            }
            Text(L10n.Bar.shortcutHelp).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var speechSection: some View {
        Section {
            Picker(L10n.Settings.speechEngine, selection: $store.current.speechEngine) {
                Text(L10n.Settings.engineAutomatic).tag(SpeechEngineKind.appleAutomatic)
                Text(L10n.Settings.engineClassic).tag(SpeechEngineKind.appleClassic)
                Text(L10n.Settings.engineOnline).tag(SpeechEngineKind.appleOnline)
            }
            Picker(L10n.Settings.language, selection: $store.current.localeIdentifier) {
                ForEach(languageChoices) { language in
                    Text(language.name).tag(language.id)
                }
            }
            Text(L10n.Settings.engineHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle(L10n.Settings.downloadModel, isOn: $store.current.downloadSpeechModel)
                .disabled(store.current.speechEngine == .appleClassic)
            Text(L10n.Settings.downloadModelHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var voiceSection: some View {
        Section(L10n.VoiceSettings.section) {
            Toggle(L10n.VoiceSettings.speakReplies, isOn: $store.current.speakReplies)
            Text(L10n.VoiceSettings.speakRepliesHelp).font(.caption).foregroundStyle(.secondary)

            Group {
                Picker(L10n.VoiceSettings.voice, selection: $store.current.voiceIdentifier) {
                    Text(L10n.VoiceSettings.bestAvailable).tag("")
                    // A voice that was chosen and has since been removed still shows, so the picker never goes blank.
                    if !store.current.voiceIdentifier.isEmpty, !voices.contains(where: { $0.id == store.current.voiceIdentifier }) {
                        Text(store.current.voiceIdentifier).tag(store.current.voiceIdentifier)
                    }
                    ForEach(voices) { voice in
                        Text(VoiceCatalog.label(voice)).tag(voice.id)
                    }
                }
                HStack {
                    Text(L10n.VoiceSettings.speed)
                    Text(L10n.VoiceSettings.slower).font(.caption).foregroundStyle(.secondary)
                    Slider(value: $store.current.speechRate, in: AppSettings.speechRateRange)
                    Text(L10n.VoiceSettings.faster).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text(L10n.VoiceSettings.improveHint).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.VoiceSettings.test) { services.voice.speakSample() }
                }
            }
            .disabled(!store.current.speakReplies)
        }
    }

    private var startupSection: some View {
        Section {
            Toggle(
                L10n.GeneralUI.startup,
                isOn: Binding(get: { login.switchIsOn }, set: { login.set($0) })
            )
            if login.needsApproval {
                HStack {
                    Text(L10n.GeneralUI.startupNeedsApproval).font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button(L10n.GeneralUI.openLoginItems) { login.openLoginItemsSettings() }
                }
            }
            if let error = login.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(L10n.GeneralUI.welcomeGuide) { services.showWelcome() }
            }
        }
    }

    /// The system's languages, plus the current selection if the system doesn't list it (so the picker never
    /// shows a blank value).
    private var languageChoices: [SpeechLanguage] {
        let selected = store.current.localeIdentifier
        guard !languages.contains(where: { $0.id == selected }) else { return languages }
        let name = Locale.current.localizedString(forIdentifier: selected) ?? selected
        return [SpeechLanguage(id: selected, name: name, supportsOnDevice: false)] + languages
    }
}
