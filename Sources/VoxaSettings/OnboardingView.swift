import KeyboardShortcuts
import SwiftUI
import VoxaCore
import VoxaPermissions

/// The first-run walkthrough: what Voxa is, the permissions it needs, which model to use, and how to start.
struct OnboardingView: View {
    /// A fixed size, like Settings, so that no layout pass ever resizes the window.
    static let contentSize = CGSize(width: 560, height: 630)

    @Bindable var store: SettingsStore
    let services: SettingsServices
    @State private var model: OnboardingModel
    let onFinish: () -> Void

    init(
        store: SettingsStore,
        services: SettingsServices,
        startingAt step: OnboardingModel.Step = .welcome,
        onFinish: @escaping () -> Void
    ) {
        self.store = store
        self.services = services
        self.onFinish = onFinish
        _model = State(
            initialValue: OnboardingModel(store: store, permissions: services.permissions, keys: services.keys, startingAt: step)
        )
    }

    private var shortcut: String {
        KeyboardShortcuts.getShortcut(for: .pushToTalk).map { "\($0)" } ?? "the shortcut"
    }

    var body: some View {
        VStack(spacing: 0) {
            progress
            Group {
                switch model.step {
                case .welcome: welcome
                case .permissions: permissions
                case .model: modelStep
                case .ready: ready
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            buttons
        }
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
        .permissionPolling(services.permissions)
        .task {
            // The key is saved in the form below, which this view can't observe, so look again every so often.
            while !Task.isCancelled {
                model.refreshTick += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: Chrome

    private var progress: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingModel.Step.allCases) { step in
                Capsule()
                    .fill(step.rawValue <= model.step.rawValue ? Color.accentColor : Color.primary.opacity(0.15))
                    .frame(width: step == model.step ? 28 : 16, height: 5)
            }
        }
        .padding(.top, 18)
        .padding(.bottom, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.Onboarding.stepLabel(model.step.rawValue + 1, of: OnboardingModel.Step.allCases.count))
    }

    private var buttons: some View {
        HStack {
            if !model.isFirst {
                Button(L10n.Onboarding.back) { model.back() }
            }
            Spacer()
            if model.isLast {
                Button(L10n.Onboarding.done) {
                    model.finish()
                    onFinish()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            } else {
                Button(nextTitle) { model.advance() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    /// "Skip for now" while what the step asks for isn't done, "Continue" once it is.
    private var nextTitle: String {
        switch model.step {
        case .permissions: model.canHear ? L10n.Onboarding.next : L10n.Onboarding.skip
        case .model: model.hasModel ? L10n.Onboarding.next : L10n.Onboarding.skip
        default: L10n.Onboarding.next
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(L10n.Onboarding.welcomeTitle).font(.largeTitle.weight(.semibold))
            VStack(alignment: .leading, spacing: 12) {
                point("hand.tap.fill", L10n.Onboarding.welcomeHold(shortcut))
                point("square.grid.2x2.fill", L10n.Onboarding.welcomeCan)
                point("checkmark.shield.fill", L10n.Onboarding.welcomeAsks)
                point("lock.fill", L10n.Onboarding.welcomePrivate)
            }
            .padding(.horizontal, 40)
        }
        .padding(.top, 8)
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.Onboarding.permissionsTitle).font(.title.weight(.semibold))
            Form {
                Section(L10n.Onboarding.permissionsNeeded) {
                    ForEach([PermissionKind.microphone, .speechRecognition], id: \.self) { kind in
                        PermissionRow(kind: kind, model: services.permissions)
                    }
                }
                Section {
                    ForEach([PermissionKind.calendars, .reminders, .accessibility, .screenRecording], id: \.self) { kind in
                        PermissionRow(kind: kind, model: services.permissions)
                    }
                } header: {
                    Text(L10n.Onboarding.permissionsOptional)
                } footer: {
                    Text(L10n.Onboarding.permissionsOptionalNote)
                }
            }
            .formStyle(.grouped)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.Onboarding.modelTitle).font(.title.weight(.semibold)).padding(.horizontal, 12)
            Text(L10n.Onboarding.modelNote).font(.callout).foregroundStyle(.secondary).padding(.horizontal, 12)
            ModelSettingsView(store: store, services: services)
        }
        .padding(.top, 8)
    }

    private var ready: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text(L10n.Onboarding.readyTitle).font(.largeTitle.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.Onboarding.readyTry(shortcut)).font(.headline)
                ForEach(L10n.Onboarding.readyExamples, id: \.self) { example in
                    Text(example).foregroundStyle(.secondary)
                }
            }

            Toggle(L10n.VoiceSettings.speakReplies, isOn: $store.current.speakReplies)
                .toggleStyle(.switch)
                .padding(.horizontal, 60)

            ForEach(model.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 40)
            }
            Text(L10n.Onboarding.readyLater)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .padding(.top, 8)
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).frame(width: 24).foregroundStyle(.tint).accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One page of the walkthrough, for the developer tool that renders every page to an image.
public struct WelcomePreview: View {
    private let store: SettingsStore
    private let services: SettingsServices
    private let step: OnboardingModel.Step

    public static var size: CGSize { OnboardingView.contentSize }
    public static let stepCount = OnboardingModel.Step.allCases.count

    public init(store: SettingsStore, services: SettingsServices, step: Int) {
        self.store = store
        self.services = services
        self.step = OnboardingModel.Step(rawValue: step) ?? .welcome
    }

    public var body: some View {
        OnboardingView(store: store, services: services, startingAt: step) {}
    }
}
