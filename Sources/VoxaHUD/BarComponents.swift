import SwiftUI
import VoxaCore

// The pieces the Voxa bar is drawn from: its look for each thing Voxa can be doing, the orb, the glow round the card, the waveform, the
// microphone button and the buttons of a question. Pure SwiftUI, so they can be hosted in a panel or rendered to an image. Nothing here
// moves by itself: the bar only changes when something happens (a word is heard, a step is taken), and the one thing that follows the
// microphone is the level meter.

/// Sizes the whole bar shares.
enum BarMetrics {
    static let width: CGFloat = 480
    static let cornerRadius: CGFloat = 30
    /// The space between the card's edge and what is drawn in it.
    static let gutter: CGFloat = 18
}

/// Voxa's own colours.
enum BarPalette {
    static let violet = Color(red: 0.56, green: 0.38, blue: 0.98)
    static let blue = Color(red: 0.24, green: 0.52, blue: 1.00)
    static let cyan = Color(red: 0.25, green: 0.78, blue: 0.95)
    static let pink = Color(red: 1.00, green: 0.36, blue: 0.62)
    static let red = Color(red: 1.00, green: 0.30, blue: 0.38)
    static let orange = Color(red: 1.00, green: 0.62, blue: 0.22)
    static let green = Color(red: 0.22, green: 0.80, blue: 0.52)
    static let mint = Color(red: 0.42, green: 0.90, blue: 0.78)
    static let slate = Color(red: 0.55, green: 0.60, blue: 0.72)
}

/// How the bar looks for what Voxa is doing: the colours of its orb and of the glow round the card, and the symbol in the orb. One look
/// for everything a command goes through, so the bar reads as a single thing that changes rather than several.
enum BarLook: Equatable {
    /// Waiting: the brand's colours.
    case idle
    /// The microphone is open: warm colours.
    case listening
    /// Thinking or acting: cool colours.
    case working
    /// A question is waiting for an answer: amber when it matters, blue when it doesn't.
    case asking(sensitive: Bool)
    /// Finished.
    case done
    /// A gentle message, such as "I didn't catch that".
    case quiet
    /// Something went wrong.
    case problem

    init(mode: HUDMode, listening: HandsFreeState) {
        switch mode {
        case .idle: self = listening.isListening ? .listening : .idle
        case .preparing, .listening: self = .listening
        case .transcribing, .thinking, .acting: self = .working
        case .confirm(let prompt): self = .asking(sensitive: prompt.risk == .sensitive)
        case .result, .reply: self = .done
        case .notice: self = .quiet
        case .error: self = .problem
        }
    }

    /// The orb's three colours; the first also tints the card.
    var palette: [Color] {
        switch self {
        case .idle: [BarPalette.violet, BarPalette.blue, BarPalette.pink]
        case .listening: [BarPalette.red, BarPalette.pink, BarPalette.orange]
        case .working: [BarPalette.blue, BarPalette.violet, BarPalette.cyan]
        case .asking(let sensitive):
            sensitive
                ? [BarPalette.orange, BarPalette.red, BarPalette.pink]
                : [BarPalette.blue, BarPalette.cyan, BarPalette.violet]
        case .done: [BarPalette.green, BarPalette.mint, BarPalette.cyan]
        case .quiet: [BarPalette.slate, BarPalette.blue, BarPalette.violet]
        case .problem: [BarPalette.orange, BarPalette.red, BarPalette.pink]
        }
    }

    var tint: Color { palette[0] }

    var symbol: String {
        switch self {
        case .idle, .working: "waveform"
        case .listening: "mic.fill"
        case .asking(let sensitive): sensitive ? "hand.raised.fill" : "questionmark"
        case .done: "checkmark"
        case .quiet: "ear"
        case .problem: "exclamationmark"
        }
    }

    /// Whether a band of colour runs round the card's edge: while Voxa listens or works.
    var glows: Bool {
        switch self {
        case .listening, .working: true
        default: false
        }
    }
}

// MARK: - The orb

/// Voxa's mark: a glass orb in the colours of what Voxa is doing, with a symbol for it.
struct VoxaOrb: View {
    let look: BarLook
    var size: CGFloat = 40

    var body: some View {
        let colors = look.palette
        return ZStack {
            Circle().fill(
                LinearGradient(colors: [colors[0], colors[1].opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            ForEach(0..<3, id: \.self) { index in
                let angle = Double(index) * 2 * .pi / 3 + 0.5
                Circle()
                    .fill(colors[index])
                    .frame(width: size * 0.62, height: size * 0.62)
                    .offset(x: CGFloat(cos(angle)) * size * 0.22, y: CGFloat(sin(angle)) * size * 0.22)
                    .blur(radius: size * 0.14)
                    .opacity(0.9)
            }
            // The glint that makes it look like glass.
            Circle().fill(
                RadialGradient(
                    colors: [.white.opacity(0.55), .clear],
                    center: UnitPoint(x: 0.32, y: 0.2),
                    startRadius: 0,
                    endRadius: size * 0.6
                )
            )
            Image(systemName: look.symbol)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.45), lineWidth: 0.75))
        .shadow(color: look.tint.opacity(0.35), radius: 6, y: 2)
        .accessibilityHidden(true)
    }
}

// MARK: - The card

/// The card's surface: Liquid Glass on macOS 26, a system material elsewhere, washed with the colour of what Voxa is doing, with a
/// light edge, and a band of colour round it while Voxa listens or works.
struct BarBackground: View {
    let look: BarLook

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: BarMetrics.cornerRadius, style: .continuous)
        ZStack {
            surface(shape)
            shape.fill(look.tint.opacity(0.07))
            if look.glows {
                let gradient = AngularGradient(colors: look.palette + [look.palette[0]], center: .center)
                ZStack {
                    shape.strokeBorder(gradient, lineWidth: 4).blur(radius: 6).opacity(0.4)
                    shape.strokeBorder(gradient, lineWidth: 1.2).opacity(0.7)
                }
                .clipShape(shape)
                .allowsHitTesting(false)
            }
            shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.34), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom),
                lineWidth: 0.75
            )
        }
    }

    @ViewBuilder
    private func surface(_ shape: RoundedRectangle) -> some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            shape
                .fill(.regularMaterial)
                .overlay(shape.strokeBorder(.primary.opacity(0.10), lineWidth: 0.5))
        }
    }
}

// MARK: - Level

/// The microphone level as a row of bars that scroll past, coloured across the bar's palette: dots while it is quiet, bars as it gets
/// loud. One path, one fill.
struct WaveformView: View {
    let levels: [Float]
    var colors: [Color] = [BarPalette.violet, BarPalette.pink, BarPalette.orange]

    var body: some View {
        Canvas { context, size in
            let barWidth: CGFloat = 3
            let spacing: CGFloat = 2.5
            let pitch = barWidth + spacing
            // As many of the newest levels as fit, the newest at the right.
            let shown = levels.suffix(max(1, Int((size.width + spacing) / pitch)))
            let start = size.width - CGFloat(shown.count) * pitch + spacing
            var bars = Path()
            for (index, level) in shown.enumerated() {
                let height = max(barWidth, CGFloat(min(1, level * 1.6)) * size.height)
                bars.addRoundedRect(
                    in: CGRect(x: start + CGFloat(index) * pitch, y: (size.height - height) / 2, width: barWidth, height: height),
                    cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2)
                )
            }
            context.fill(
                bars,
                with: .linearGradient(Gradient(colors: colors), startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: size.width, y: 0))
            )
        }
        .accessibilityElement()
        .accessibilityLabel(L10n.HUD.meterLabel)
    }
}

/// The waveform, reading the levels itself, so that a level arriving ~45 times a second re-draws only the waveform and not the whole bar.
struct LiveWaveform: View {
    let content: HUDModel
    var colors: [Color] = [BarPalette.violet, BarPalette.pink, BarPalette.orange]

    var body: some View {
        WaveformView(levels: content.levels, colors: colors)
    }
}

// MARK: - The microphone button

/// The microphone: plain while off, red while it listens, dimmed while Voxa works, and crossed out when it can't listen.
struct MicrophoneButton: View {
    let model: CommandBarModel

    var body: some View {
        Button {
            model.toggleListening()
        } label: {
            ZStack {
                Circle().fill(fill)
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(symbolColor)
            }
            .frame(width: 38, height: 38)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(model.listening.isOn ? L10n.Bar.stopListening : L10n.Bar.startListening)
        .accessibilityLabel(model.listening.isOn ? L10n.Bar.stopListening : L10n.Bar.startListening)
        .accessibilityAddTraits(model.listening.isOn ? .isSelected : [])
    }

    private var fill: AnyShapeStyle {
        switch model.listening {
        case .off: AnyShapeStyle(.primary.opacity(0.07))
        case .starting, .listening:
            AnyShapeStyle(
                LinearGradient(colors: [BarPalette.red, BarPalette.pink], startPoint: .topLeading, endPoint: .bottomTrailing)
            )
        case .paused: AnyShapeStyle(BarPalette.red.opacity(0.4))
        case .unavailable: AnyShapeStyle(BarPalette.orange.opacity(0.18))
        }
    }

    private var symbol: String {
        switch model.listening {
        case .off: "mic"
        case .unavailable: "mic.slash.fill"
        case .starting, .listening, .paused: "mic.fill"
        }
    }

    private var symbolColor: Color {
        switch model.listening {
        case .off: .secondary
        case .unavailable: BarPalette.orange
        case .starting, .listening, .paused: .white
        }
    }
}

// MARK: - Small things

/// A key, drawn as a key: `esc`, `⌘↩`. `onTint` is for one drawn on a coloured button, where it is white.
struct KeyCap: View {
    private let text: String
    private let onTint: Bool

    init(_ text: String, onTint: Bool = false) {
        self.text = text
        self.onTint = onTint
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(onTint ? AnyShapeStyle(.white.opacity(0.92)) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(onTint ? AnyShapeStyle(.white.opacity(0.22)) : AnyShapeStyle(.primary.opacity(0.09)))
            )
            .accessibilityHidden(true)
    }
}

/// "esc to cancel", the way out of anything under way.
struct CancelHint: View {
    var body: some View {
        HStack(spacing: 6) {
            KeyCap(L10n.HUD.escapeKeyLabel)
            Text(L10n.HUD.cancelHint)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The buttons of a question: a pill filled with the colour of what is being asked, or a plain one.
struct PillButtonStyle: ButtonStyle {
    enum Kind {
        case prominent(Color)
        case plain
    }

    let kind: Kind
    /// Whether it fills the width it is given (a pair of buttons), or is only as wide as its label (a lone one).
    var expands = true

    func makeBody(configuration: Configuration) -> some View {
        Pill(configuration: configuration, kind: kind, expands: expands)
    }

    private struct Pill: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        let expands: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, expands ? 0 : 20)
                .frame(maxWidth: expands ? .infinity : nil, minHeight: 38)
                .background(background, in: Capsule())
                .contentShape(Capsule())
                .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.45)
        }

        private var foreground: Color {
            if case .prominent = kind { return .white }
            return .primary
        }

        private var background: AnyShapeStyle {
            switch kind {
            case .prominent(let tint):
                AnyShapeStyle(LinearGradient(colors: [tint, tint.opacity(0.78)], startPoint: .top, endPoint: .bottom))
            case .plain:
                AnyShapeStyle(.primary.opacity(0.09))
            }
        }
    }
}
