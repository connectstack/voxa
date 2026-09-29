import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Hold to talk, release to send. Defaults to ⌥Space so the app works out of the box; the user can rebind it in
    /// Settings (KeyboardShortcuts persists the choice and warns about conflicts with system shortcuts).
    public static let pushToTalk = Self("pushToTalk", initial: .init(.space, modifiers: [.option]))
}
