import Foundation
import VoxaCore

/// Reading and writing the dates that tools trade with the model, in one place.
///
/// The model is told to pass ISO 8601 timestamps with a UTC offset (`2026-09-30T15:00:00+05:30`), and gets them back in the
/// same form, so there is no guessing about time zones in either direction. Because a transcript-driven model sometimes
/// leaves the offset off, or gives only a day, both are accepted: a time with no offset is the user's local time, and a bare
/// date (`2026-09-30`) means the whole day.
public struct ToolDates: Sendable {
    /// What a parsed timestamp turned out to be.
    public enum Parsed: Sendable, Equatable {
        /// A moment in time.
        case moment(Date)
        /// A whole day, given as a date with no time; the value is that day's start in the user's time zone.
        case day(Date)

        public var date: Date {
            switch self {
            case .moment(let date), .day(let date): date
            }
        }

        public var isDayOnly: Bool {
            if case .day = self { true } else { false }
        }
    }

    public var timeZone: TimeZone
    public var locale: Locale

    public init(timeZone: TimeZone = .current, locale: Locale = .current) {
        self.timeZone = timeZone
        self.locale = locale
    }

    /// The user's time zone and language as they are right now.
    public static var current: ToolDates { ToolDates() }

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = locale
        return calendar
    }

    // MARK: Reading

    /// The shapes accepted, for error messages the model can correct itself with.
    public static let expected = "an ISO 8601 timestamp with a UTC offset such as 2026-09-30T15:00:00+05:30 (or a date such as 2026-09-30)"

    public func parse(_ text: String) -> Parsed? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        for options: ISO8601DateFormatter.Options in [
            [.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds],
        ] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: trimmed) { return .moment(date) }
        }
        // No offset: the user's own clock.
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            if let date = formatter(format).date(from: trimmed) { return .moment(date) }
        }
        if let day = formatter("yyyy-MM-dd").date(from: trimmed) { return .day(calendar.startOfDay(for: day)) }
        return nil
    }

    private func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        // A strict parse: "2026-02-31" must fail rather than roll over into March.
        formatter.isLenient = false
        return formatter
    }

    // MARK: Writing

    /// `2026-09-30T15:00:00+05:30`: what the model gets back, and what it can pass on unchanged.
    public func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// `2026-09-30`
    public func isoDay(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withFullDate]
        return formatter.string(from: date)
    }

    /// A person's reading of a span: `Tue 30 Sep, 3:00 – 3:30 PM`, or for all-day events `Tue 30 Sep (all day)`.
    public func label(from start: Date, to end: Date, allDay: Bool = false) -> String {
        let day = Date.FormatStyle(locale: locale, timeZone: timeZone).weekday(.abbreviated).day().month(.abbreviated)
        let time = Date.FormatStyle(locale: locale, timeZone: timeZone).hour().minute()

        if allDay {
            // An all-day event's end is the start of the day after it ends.
            let lastDay = calendar.date(byAdding: .day, value: -1, to: end).map { max($0, start) } ?? end
            if calendar.isDate(start, inSameDayAs: lastDay) { return "\(start.formatted(day)) (all day)" }
            return "\(start.formatted(day)) – \(lastDay.formatted(day)) (all day)"
        }
        if calendar.isDate(start, inSameDayAs: end) {
            return "\(start.formatted(day)), \(start.formatted(time)) – \(end.formatted(time))"
        }
        return "\(start.formatted(day)), \(start.formatted(time)) – \(end.formatted(day)), \(end.formatted(time))"
    }

    /// `Tue 30 Sep, 3:00 PM`, or the day alone for a date with no time.
    public func label(_ date: Date, dayOnly: Bool = false) -> String {
        let day = Date.FormatStyle(locale: locale, timeZone: timeZone).weekday(.abbreviated).day().month(.abbreviated)
        guard !dayOnly else { return date.formatted(day) }
        let time = Date.FormatStyle(locale: locale, timeZone: timeZone).hour().minute()
        return "\(date.formatted(day)), \(date.formatted(time))"
    }
}
