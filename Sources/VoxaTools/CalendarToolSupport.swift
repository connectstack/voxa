import Foundation
import VoxaCore

/// What the calendar tools share: reading arguments the model got wrong in the usual ways, and writing events back in a form
/// the model can copy an `id` and `start` from.
enum CalendarToolSupport {
    static let maxTitleCharacters = 200
    static let maxTimedEventDays = 14
    static let maxAllDayEventDays = 60
    static let defaultDurationMinutes = 60

    /// Reads a timestamp argument, or explains what would have been accepted.
    static func parse(_ text: String, argument: String, dates: ToolDates) throws -> ToolDates.Parsed {
        guard let parsed = dates.parse(text) else {
            throw ToolInputError("Argument '\(argument)' isn't a date and time. Use \(ToolDates.expected).")
        }
        return parsed
    }

    /// The calendar named by the model, matched without regard to case; nil means the user's default.
    static func resolveCalendar(_ name: String?, in calendars: [CalendarInfo], forWriting: Bool) throws -> CalendarInfo? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        guard let match = calendars.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            let available = calendars.filter { !forWriting || $0.allowsModifications }.map(\.name)
            throw ToolInputError(CalendarError.calendarNotFound(name, available: available).localizedDescription)
        }
        if forWriting, !match.allowsModifications {
            throw ToolInputError(CalendarError.calendarIsReadOnly(match.name).localizedDescription)
        }
        return match
    }

    /// A span of an event, by moment or (for all-day events) by whole days, from the arguments of a create or update.
    struct Span {
        var start: Date
        var end: Date
        var isAllDay: Bool
    }

    /// Works out when a new event happens from what was said. A timed event needs a start time and gets an hour unless an end
    /// or a duration is given; an all-day event needs only a date and may name its last day.
    static func span(
        start: String,
        end: String?,
        durationMinutes: Int?,
        allDay: Bool,
        dates: ToolDates
    ) throws -> Span {
        let calendar = dates.calendar
        let first = try parse(start, argument: "start", dates: dates)

        if allDay {
            if durationMinutes != nil {
                throw ToolInputError("An all-day event has no duration_minutes. Give end (its last day) if it lasts more than a day.")
            }
            let firstDay = calendar.startOfDay(for: first.date)
            let lastDay = try end.map { calendar.startOfDay(for: try parse($0, argument: "end", dates: dates).date) } ?? firstDay
            guard lastDay >= firstDay else { throw ToolInputError("The end is before the start.") }
            let days = calendar.dateComponents([.day], from: firstDay, to: lastDay).day ?? 0
            guard days < maxAllDayEventDays else { throw ToolInputError("An all-day event can span at most \(maxAllDayEventDays) days.") }
            // EventKit's end for an all-day event is the start of the day after it.
            let exclusiveEnd = calendar.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay
            return Span(start: firstDay, end: exclusiveEnd, isAllDay: true)
        }

        guard !first.isDayOnly else {
            throw ToolInputError("Argument 'start' has a date but no time. Give a time, or set all_day to true for an all-day event.")
        }
        if end != nil, durationMinutes != nil {
            throw ToolInputError("Give either end or duration_minutes, not both.")
        }
        let finish: Date
        if let end {
            let parsed = try parse(end, argument: "end", dates: dates)
            guard !parsed.isDayOnly else { throw ToolInputError("Argument 'end' has a date but no time.") }
            finish = parsed.date
        } else {
            finish = first.date.addingTimeInterval(TimeInterval((durationMinutes ?? defaultDurationMinutes) * 60))
        }
        guard finish > first.date else { throw ToolInputError("The end must be after the start.") }
        guard finish.timeIntervalSince(first.date) <= TimeInterval(maxTimedEventDays * 86_400) else {
            throw ToolInputError("An event can last at most \(maxTimedEventDays) days. Check the dates.")
        }
        return Span(start: first.date, end: finish, isAllDay: false)
    }

    // MARK: Writing events back

    /// One event as a block of `key: value` lines. `id` and `start` are what an update or a delete needs.
    static func describe(_ event: CalendarEvent, number: Int, dates: ToolDates, noteLimit: Int = 300) -> String {
        let last = event.isAllDay ? (dates.calendar.date(byAdding: .day, value: -1, to: event.end) ?? event.end) : event.end
        var lines = [
            "\(number). \(event.title) — \(dates.label(from: event.start, to: event.end, allDay: event.isAllDay)) (\(event.calendar))",
            "   start: \(event.isAllDay ? dates.isoDay(event.start) : dates.iso(event.start))",
            "   end: \(event.isAllDay ? dates.isoDay(max(last, event.start)) : dates.iso(event.end))",
            "   id: \(event.id)",
        ]
        if event.isAllDay { lines.append("   all day: yes") }
        if let location = event.location, !location.isEmpty { lines.append("   location: \(location)") }
        if let url = event.url, !url.isEmpty { lines.append("   link: \(url)") }
        if event.isRecurring { lines.append("   repeats: yes") }
        if event.hasAttendees { lines.append("   other people invited: yes") }
        if let notes = event.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            let flat = notes.replacingOccurrences(of: "\n", with: " ")
            lines.append("   notes: \(flat.count > noteLimit ? String(flat.prefix(noteLimit)) + "…" : flat)")
        }
        return lines.joined(separator: "\n")
    }

    /// The `id` and `start` an update or delete must be given, for an event this code just made or changed.
    static func reference(_ event: CalendarEvent, dates: ToolDates) -> String {
        "id: \(event.id), start: \(event.isAllDay ? dates.isoDay(event.start) : dates.iso(event.start))"
    }

    /// A short name for an event, safe to put in a title line.
    static func shortTitle(_ title: String, limit: Int = 60) -> String {
        let flat = title.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }
}
