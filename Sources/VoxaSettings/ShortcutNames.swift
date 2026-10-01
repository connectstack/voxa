import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Hold to talk, release to send. Defaults to ⌥Space so the app works out of the box; the user can rebind it in
    /// Settings (KeyboardShortcuts persists the choice and warns about conflicts with system shortcuts).
    public static let pushToTalk = Self("pushToTalk", initial: .init(.space, modifiers: [.option]))

    /// Opens the Voxa bar: the field to type a command in, and the microphone button (click it, talk, click it again). ⌥⇧Space beside
    /// push-to-talk's ⌥Space, and clear of the system's own (⌘Space, ⌥⌘Space, ⌃Space and ⌃⌥Space are all taken).
    public static let openBar = Self("openBar", initial: .init(.space, modifiers: [.option, .shift]))
}
