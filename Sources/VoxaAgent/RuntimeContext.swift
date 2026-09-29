import Foundation

/// The per-request facts the model needs and the system prompt must not contain: the current date and time.
///
/// Only values Voxa itself produces belong here. Anything that comes from outside (window titles, clipboard, file
/// names) is untrusted and must reach the model through a tool result wrapped as untrusted data instead.
public struct RuntimeContext: Sendable, Equatable {
    public var now: Date
    public var timeZone: TimeZone
    public var locale: Locale
    public var operatingSystem: String

    public init(
        now: Date = Date(),
        timeZone: TimeZone = .current,
        locale: Locale = .current,
        operatingSystem: String = ProcessInfo.processInfo.operatingSystemVersionString
    ) {
        self.now = now
        self.timeZone = timeZone
        self.locale = locale
        self.operatingSystem = operatingSystem
    }

    /// A compact block for the start of the user turn. Dates are unambiguous (weekday, ISO 8601 with offset) so the
    /// model can resolve "tomorrow at three" without guessing the zone.
    public func render() -> String {
        let iso = ISO8601DateFormatter()
        iso.timeZone = timeZone
        iso.formatOptions = [.withInternetDateTime]

        let weekday = Date.FormatStyle(locale: Locale(identifier: "en_US_POSIX"), timeZone: timeZone)
            .weekday(.wide)

        return """
        <context>
        Now: \(now.formatted(weekday)), \(iso.string(from: now))
        Time zone: \(timeZone.identifier)
        User locale: \(locale.identifier)
        macOS: \(operatingSystem)
        </context>
        """
    }
}
