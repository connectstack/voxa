import SwiftUI
import VoxaCore

/// Everything Voxa has to say below the bar's field: what it is doing, what it heard, its reply, a problem, and the question it needs
/// answered. It is part of the bar, not a window of its own: the same card, and the same look.
struct BarContent: View {
    let input: CommandBarModel
    let content: HUDModel
    let look: BarLook

    /// Whether there is anything to show below the field. (A bar with nothing to say is only the field.)
    static func hasContent(input: CommandBarModel, content: HUDModel) -> Bool {
        switch content.mode {
        case .idle: !input.lines.isEmpty
        // The title is in the row when nothing was heard, and then only the rest is below.
        case .notice(_, let detail): content.headline == nil || detail != nil
        case .error(let error): content.headline == nil || !error.detail.isEmpty || error.recovery != nil
        default: true
        }
    }

    var body: some View {
        if Self.hasContent(input: input, content: content) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(.primary.opacity(0.08))
                    .frame(height: 0.5)
                    .padding(.horizontal, 16)
                VStack(alignment: .leading, spacing: 12) {
                    section
                    // What stopped a command from being taken, while another runs.
                    if content.mode != .idle, let note = input.note {
                        CaptionLine(line: CommandBarModel.Line(text: note, tone: .plain))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, BarMetrics.gutter)
                .padding(.top, 14)
                .padding(.bottom, 16)
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var section: some View {
        switch content.mode {
        case .idle:
            idle
        case .preparing:
            LiveWaveform(content: content).frame(height: 30)
            StatusRow(title: L10n.HUD.preparing) { CancelHint() }
        case .listening:
            LiveWaveform(content: content).frame(height: 30)
            StatusRow(title: L10n.HUD.listening, subtitle: listeningHint) { CancelHint() }
        case .transcribing:
            StatusRow(title: L10n.HUD.transcribing) { CancelHint() }
        case .result:
            StatusRow(title: L10n.HUD.heard, subtitle: L10n.HUD.notConnectedYet) { EmptyView() }
        case .thinking(let partial):
            thinking(partial)
        case .acting(let title):
            StatusRow(title: title) { CancelHint() }
        case .confirm(let prompt):
            ConfirmationCard(prompt: prompt, content: content, look: look)
        case .reply(let text):
            reply(text)
        case .error(let error):
            problem(error)
        case .notice(let title, let detail):
            message(title: content.headline == nil ? title : nil, detail: detail)
        }
    }

    /// What to do to send what is being said: click the microphone again, when its button started it; let go of the key, when one is
    /// held.
    private var listeningHint: String? {
        content.endsOnClick ? L10n.HUD.clickToSend : content.hotkeyHint.map(L10n.HUD.releaseToSend)
    }

    /// Waiting with the bar open: what there is to know (why something didn't happen, what full control changes).
    @ViewBuilder
    private var idle: some View {
        let lines = input.lines
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    CaptionLine(line: line)
                }
            }
        }
    }

    private func thinking(_ partial: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            StatusRow(title: L10n.HUD.thinking) { CancelHint() }
            if let partial, !partial.isEmpty {
                Text(verbatim: partial)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func reply(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: text)
                .font(.system(size: 16))
                .lineSpacing(3)
                .lineLimit(10)
                .fixedSize(horizontal: false, vertical: true)
            if let hint = content.hotkeyHint {
                Text(L10n.HUD.followUpHint(hint))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func message(title: String?, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let title {
                Text(verbatim: title)
                    .font(.system(size: 15, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let detail, !detail.isEmpty {
                Text(verbatim: detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func problem(_ error: UserFacingError) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            message(title: content.headline == nil ? error.title : nil, detail: error.detail)
            if let recovery = error.recovery {
                Button(recovery.title) { content.onRecovery?(recovery) }
                    .buttonStyle(PillButtonStyle(kind: .prominent(BarPalette.orange), expands: false))
            }
        }
    }
}

// MARK: - Pieces

/// One line of status: what is going on, and how to stop it on the right.
private struct StatusRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            titleText
            if let subtitle {
                Text(verbatim: subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing
        }
        .accessibilityElement(children: .combine)
    }

    private var titleText: some View {
        Text(verbatim: title)
            .font(.system(size: 14, weight: .semibold))
            .lineLimit(2)
    }
}

/// A line of small print under the field: a note, a warning, a problem.
struct CaptionLine: View {
    let line: CommandBarModel.Line

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(verbatim: line.text)
                .font(.system(size: 12))
                .foregroundStyle(line.tone == .plain ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch line.tone {
        case .plain: "info.circle"
        case .warning: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch line.tone {
        case .plain: .secondary
        case .warning: BarPalette.orange
        }
    }
}

// MARK: - The question

/// What the person is asked to approve: the exact details from the tool's own code, why Voxa is asking, and how to answer.
private struct ConfirmationCard: View {
    let prompt: ConfirmationPrompt
    let content: HUDModel
    let look: BarLook

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: prompt.title)
                    .font(.system(size: 15, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: prompt.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !prompt.details.isEmpty { details }
            if !prompt.reasons.isEmpty { reasons }
            buttons
            footer
        }
    }

    private var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(prompt.details.enumerated()), id: \.offset) { _, row in
                    DetailRowView(row: row)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 190)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.primary.opacity(0.06)))
    }

    private var reasons: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(prompt.reasons.enumerated()), id: \.offset) { _, reason in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: prompt.risk == .sensitive ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(prompt.risk == .sensitive ? BarPalette.orange : Color.secondary)
                        .accessibilityHidden(true)
                    Text(verbatim: reason)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.HUD.reasonsLabel)
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Button {
                content.onConfirmationChoice?(.deny)
            } label: {
                HStack(spacing: 7) {
                    Text(L10n.HUD.dontAllow)
                    KeyCap(L10n.HUD.escapeKeyLabel)
                }
            }
            .buttonStyle(PillButtonStyle(kind: .plain))

            Button {
                content.onConfirmationChoice?(.allow)
            } label: {
                HStack(spacing: 7) {
                    Text(L10n.HUD.allow)
                    KeyCap(L10n.HUD.allowKeyLabel, onTint: true)
                }
            }
            .buttonStyle(PillButtonStyle(kind: .prominent(look.tint)))
            .disabled(!content.confirmationKeysEnabled)
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch content.answerStatus {
        case .idle:
            Text(content.hotkeyHint.map(L10n.HUD.voiceAnswerHint) ?? L10n.HUD.voiceAnswerHintNoShortcut)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        case .listening:
            Text(L10n.HUD.answerListening)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(BarPalette.red)
        case .unclear:
            Text(L10n.HUD.answerUnclear)
                .font(.system(size: 12))
                .foregroundStyle(BarPalette.orange)
        }
    }
}

private struct DetailRowView: View {
    let row: DetailRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: row.label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            switch row.style {
            case .plain:
                Text(verbatim: row.value)
                    .font(.system(size: 13))
            case .code:
                Text(verbatim: row.value)
                    .font(.system(size: 12, design: .monospaced))
            case .url:
                // Never truncated: the box scrolls instead, because the middle of an address is where a leak hides.
                Text(verbatim: row.value)
                    .font(.system(size: 13, design: .monospaced))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}
