import SwiftUI
import VoxaCore

/// The floating command HUD: live transcript, status, and the microphone level. Pure SwiftUI over `HUDModel` so it can
/// be hosted in a panel, rendered to an image for snapshots, or previewed.
public struct HUDView: View {
    private let model: HUDModel
    private let onSizeChange: (@MainActor (CGSize) -> Void)?

    /// - Parameter onSizeChange: Called (asynchronously, on the main actor) whenever the content's size changes. The
    ///   window controller uses it to resize the panel. Sizing goes through this callback rather than through Auto
    ///   Layout because constraint-driven window resizing makes `NSHostingView` request a constraints update in the
    ///   middle of the window's layout pass on macOS 26, which AppKit answers by throwing.
    public init(model: HUDModel, onSizeChange: (@MainActor (CGSize) -> Void)? = nil) {
        self.model = model
        self.onSizeChange = onSizeChange
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.mode.showsTranscript {
                transcriptText
            }
            if case .reply(let text) = model.mode {
                replyText(text)
            }
            if case .confirm(let prompt) = model.mode {
                ConfirmationCard(prompt: prompt, model: model)
            }
            if case .error(let error) = model.mode, let recovery = error.recovery {
                Button(recovery.title) { model.onRecovery?(recovery) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            if model.mode.showsCancelHint {
                cancelHint
            }
            if case .reply = model.mode, let hint = model.hotkeyHint {
                Text(L10n.HUD.followUpHint(hint))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 440, alignment: .leading)
        // The HUD's height is its content's natural height, whatever the window currently proposes. Without this, a
        // ScrollView inside (the confirmation's details) shrinks to the current window height and the window never grows.
        .fixedSize(horizontal: false, vertical: true)
        .background(HUDBackground())
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: HUDSizeKey.self, value: proxy.size)
            }
        }
        .onPreferenceChange(HUDSizeKey.self) { size in
            // Hop to the main actor on a fresh turn: never resize the window from inside SwiftUI's update pass.
            Task { @MainActor in onSizeChange?(size) }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 12) {
            StatusGlyph(mode: model.mode, level: model.levels.last ?? 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if model.mode.showsMeter {
                WaveformView(levels: model.levels)
                    .frame(width: 120, height: 26)
                    .accessibilityElement()
                    .accessibilityLabel(L10n.HUD.meterLabel)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var transcriptText: some View {
        let isEmpty = model.transcript.isEmpty
        return Text(isEmpty ? L10n.HUD.placeholder : model.transcript)
            .font(.title3.weight(.medium))
            .foregroundStyle(transcriptStyle(isEmpty: isEmpty))
            .lineLimit(4)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityHidden(isEmpty)
    }

    private func replyText(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.title3.weight(.medium))
            .lineLimit(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var cancelHint: some View {
        HStack(spacing: 6) {
            Text(L10n.HUD.escapeKeyLabel)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.quaternary))
            Text(L10n.HUD.cancelHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Text

    private var title: String {
        switch model.mode {
        case .preparing: L10n.HUD.preparing
        case .listening: L10n.HUD.listening
        case .transcribing: L10n.HUD.transcribing
        case .result: L10n.HUD.heard
        case .notice(let title, _): title
        case .error(let error): error.title
        case .thinking: L10n.HUD.thinking
        case .acting(let title): title
        case .confirm(let prompt): prompt.title
        case .reply: L10n.HUD.replyTitle
        }
    }

    private var subtitle: String? {
        switch model.mode {
        case .listening, .preparing: model.hotkeyHint.map(L10n.HUD.releaseToSend)
        case .result: L10n.HUD.notConnectedYet
        case .notice(_, let detail): detail
        case .error(let error): error.detail
        case .thinking(let partial): partial
        case .confirm(let prompt): prompt.summary
        case .transcribing, .acting, .reply: nil
        }
    }

    private func transcriptStyle(isEmpty: Bool) -> AnyShapeStyle {
        if isEmpty { return AnyShapeStyle(.tertiary) }
        if model.isTranscriptFinal { return AnyShapeStyle(.primary) }
        if case .result = model.mode { return AnyShapeStyle(.primary) }
        return AnyShapeStyle(.secondary)
    }
}

// MARK: - Pieces

private struct HUDSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

extension HUDMode {
    /// Modes where work is in progress and the glyph is a spinner.
    fileprivate var isBusy: Bool {
        switch self {
        case .transcribing, .thinking, .acting: true
        default: false
        }
    }
}

private struct StatusGlyph: View {
    let mode: HUDMode
    let level: Float

    var body: some View {
        ZStack {
            if case .listening = mode {
                Circle()
                    .fill(tint.opacity(0.22))
                    .scaleEffect(1 + CGFloat(level) * 0.55)
                    .animation(.easeOut(duration: 0.1), value: level)
            }
            Circle().fill(tint.opacity(0.16))
            if mode.isBusy {
                Spinner()
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: 34, height: 34)
        .accessibilityHidden(true)
    }

    private var symbol: String {
        switch mode {
        case .preparing, .listening: "mic.fill"
        case .transcribing: "ellipsis"
        case .result: "checkmark"
        case .notice: "ear"
        case .error: "exclamationmark.triangle.fill"
        case .thinking, .acting: "ellipsis"
        case .confirm(let prompt): prompt.risk == .sensitive ? "hand.raised.fill" : "questionmark"
        case .reply: "checkmark"
        }
    }

    private var tint: Color {
        switch mode {
        case .listening: .red
        case .preparing, .transcribing, .notice, .thinking, .acting: .secondary
        case .result, .reply: .green
        case .error: .orange
        case .confirm(let prompt): prompt.risk == .sensitive ? .orange : .blue
        }
    }
}

/// What the user is asked to approve: the exact details from the tool's own code, why Voxa is asking, and how to answer.
private struct ConfirmationCard: View {
    let prompt: ConfirmationPrompt
    let model: HUDModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !prompt.details.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(prompt.details.enumerated()), id: \.offset) { _, row in
                            DetailRowView(row: row)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 190)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.6)))
            }
            if !prompt.reasons.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(prompt.reasons.enumerated()), id: \.offset) { _, reason in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: prompt.risk == .sensitive ? "exclamationmark.triangle.fill" : "info.circle.fill")
                                .font(.caption)
                                .foregroundStyle(prompt.risk == .sensitive ? Color.orange : Color.secondary)
                                .accessibilityHidden(true)
                            Text(verbatim: reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(L10n.HUD.reasonsLabel)
            }
            buttons
            footer
        }
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Button {
                model.onConfirmationChoice?(.deny)
            } label: {
                HStack(spacing: 6) {
                    Text(L10n.HUD.dontAllow)
                    KeyCap(L10n.HUD.escapeKeyLabel)
                }
            }
            .controlSize(.large)

            Spacer(minLength: 0)

            Button {
                model.onConfirmationChoice?(.allow)
            } label: {
                HStack(spacing: 6) {
                    Text(L10n.HUD.allow)
                    KeyCap(L10n.HUD.allowKeyLabel)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.confirmationKeysEnabled)
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch model.answerStatus {
        case .idle:
            Text(model.hotkeyHint.map(L10n.HUD.voiceAnswerHint) ?? L10n.HUD.voiceAnswerHintNoShortcut)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .listening:
            Text(L10n.HUD.answerListening)
                .font(.caption.weight(.medium))
                .foregroundStyle(.red)
        case .unclear:
            Text(L10n.HUD.answerUnclear)
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}

private struct DetailRowView: View {
    let row: DetailRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: row.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            switch row.style {
            case .plain:
                Text(verbatim: row.value)
                    .font(.callout)
            case .code:
                Text(verbatim: row.value)
                    .font(.system(.caption, design: .monospaced))
            case .url:
                // Never truncated: the box scrolls instead, because the middle of an address is where a leak hides.
                Text(verbatim: row.value)
                    .font(.system(.callout, design: .monospaced))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

private struct KeyCap: View {
    private let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.quaternary))
            .accessibilityHidden(true)
    }
}

/// A pure-SwiftUI spinner. (`ProgressView` is AppKit-backed on macOS, which can't be rendered offscreen for snapshots
/// and previews.)
private struct Spinner: View {
    @State private var rotation = 0.0

    var body: some View {
        Circle()
            .trim(from: 0.12, to: 0.85)
            .stroke(.secondary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .frame(width: 16, height: 16)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

private struct WaveformView: View {
    let levels: [Float]

    var body: some View {
        Canvas { context, size in
            let count = levels.count
            guard count > 1 else { return }
            let spacing: CGFloat = 2
            let barWidth = (size.width - spacing * CGFloat(count - 1)) / CGFloat(count)
            for (index, level) in levels.enumerated() {
                let amplitude = CGFloat(min(1, level * 1.5))
                let height = max(2, amplitude * size.height)
                let rect = CGRect(
                    x: CGFloat(index) * (barWidth + spacing),
                    y: (size.height - height) / 2,
                    width: barWidth,
                    height: height
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth / 2),
                    with: .color(.primary.opacity(0.3 + 0.55 * Double(amplitude)))
                )
            }
        }
    }
}

/// Liquid Glass on macOS 26, a system material elsewhere.
private struct HUDBackground: View {
    private let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)

    var body: some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            shape
                .fill(.regularMaterial)
                .overlay(shape.strokeBorder(.primary.opacity(0.10), lineWidth: 0.5))
        }
    }
}
