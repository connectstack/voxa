import SwiftUI
import VoxaCore

/// The Voxa bar: one glass card that holds a field to type a command in, Voxa's orb, a microphone button (click it, say the command,
/// click it again to send), and, below them, everything Voxa has to say while it works: what it heard, its progress, its reply, a
/// problem, and the question it needs answered. Pure SwiftUI over `CommandBarModel` (the field and the microphone) and `HUDModel` (what is below), so it
/// can be hosted in a panel or drawn to an image.
public struct CommandBarView: View {
    private let input: CommandBarModel
    private let content: HUDModel
    private let onSizeChange: (@MainActor (CGSize) -> Void)?
    @FocusState private var fieldFocused: Bool

    public static let width = BarMetrics.width

    /// - Parameter onSizeChange: Called (asynchronously, on the main actor) whenever the content's size changes. The window controller
    ///   uses it to resize the panel. Sizing goes through this callback rather than through Auto Layout because constraint-driven
    ///   window resizing makes `NSHostingView` request a constraints update in the middle of the window's layout pass on macOS 26,
    ///   which AppKit answers by throwing.
    public init(model: CommandBarModel, content: HUDModel = HUDModel(), onSizeChange: (@MainActor (CGSize) -> Void)? = nil) {
        self.input = model
        self.content = content
        self.onSizeChange = onSizeChange
    }

    public var body: some View {
        let look = BarLook(mode: content.mode)
        VStack(spacing: 0) {
            row(look: look)
            BarContent(input: input, content: content, look: look)
        }
        .frame(width: Self.width, alignment: .leading)
        // The card's height is its content's natural height, whatever the window currently proposes. Without this, a ScrollView inside
        // (a question's details) shrinks to the current window height and the window never grows.
        .fixedSize(horizontal: false, vertical: true)
        .background(BarBackground(look: look))
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: BarSizeKey.self, value: proxy.size)
            }
        }
        .onPreferenceChange(BarSizeKey.self) { size in
            // Hop to the main actor on a fresh turn: never resize the window from inside SwiftUI's update pass.
            Task { @MainActor in onSizeChange?(size) }
        }
        .onChange(of: input.focusRequests) { fieldFocused = true }
        .accessibilityElement(children: .contain)
    }

    // MARK: The row

    /// The orb, what was typed or said, and the microphone.
    private func row(look: BarLook) -> some View {
        HStack(spacing: 12) {
            VoxaOrb(look: look)
            center
            if input.isOpen {
                MicrophoneButton(model: input, content: content)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, input.isOpen ? 13 : BarMetrics.gutter)
        .padding(.vertical, 12)
        .frame(minHeight: 64)
    }

    /// The field while the bar is waiting for a command; while one is under way, the command itself.
    @ViewBuilder
    private var center: some View {
        if input.isOpen && content.mode.allowsTyping {
            TextField(L10n.Bar.placeholder, text: Bindable(input).text)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .focused($fieldFocused)
                .onSubmit { input.submit() }
                .onExitCommand { input.escape() }
                .onAppear { fieldFocused = true }
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                .accessibilityLabel(L10n.Bar.fieldLabel)
        } else {
            echo
        }
    }

    /// What Voxa was told: typed, or heard as it is being said. Until there are words, what it is waiting for.
    private var echo: some View {
        let words = content.headline ?? content.transcript
        let isFinal = content.headline != nil || content.isTranscriptFinal
        return Text(verbatim: words.isEmpty ? echoPlaceholder : words)
            .font(.system(size: 18))
            .foregroundStyle(words.isEmpty ? AnyShapeStyle(.tertiary) : isFinal ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .lineLimit(3)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityHidden(words.isEmpty)
    }

    private var echoPlaceholder: String {
        switch content.mode {
        case .preparing: L10n.HUD.preparing
        case .listening: L10n.HUD.placeholder
        case .transcribing: L10n.HUD.transcribing
        default: L10n.Bar.placeholder
        }
    }
}

private struct BarSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}
