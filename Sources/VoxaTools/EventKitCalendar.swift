import EventKit
import Foundation
import VoxaCore

/// The user's real calendars, through EventKit.
///
/// It assumes Calendar access has been granted: the agent loop makes sure of that before any calendar tool runs (see
/// `ToolPermissionGranting`). Without it EventKit simply returns nothing, which is why the tools are never given this type
/// until the permission is in place.
///
/// EventKit isn't documented as safe to call from several threads at once, so every call takes a lock.
public final class EventKitCalendar: CalendarAccessing, @unchecked Sendable {
    private let store: EKEventStore
    private let lock = NSLock()

    public init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: Reading

    public func calendars() -> [CalendarInfo] {
        locked {
            store.calendars(for: .event).map { CalendarInfo(name: $0.title, allowsModifications: $0.allowsContentModifications) }
        }
    }

    public func events(from start: Date, to end: Date, calendars names: [String]?, limit: Int) throws -> [CalendarEvent] {
        locked {
            let selected = names.map { names in
                store.calendars(for: .event).filter { calendar in
                    names.contains { $0.caseInsensitiveCompare(calendar.title) == .orderedSame }
                }
            }
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: selected)
            return store.events(matching: predicate)
                .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
                .prefix(limit)
                .map(Self.convert)
        }
    }

    public func event(id: String, start: Date?) throws -> CalendarEvent? {
        locked { find(id: id, start: start).map(Self.convert) }
    }

    // MARK: Writing

    public func create(_ event: NewCalendarEvent) throws -> CalendarEvent {
        try locked {
            let target = try writableCalendar(named: event.calendar)
            let created = EKEvent(eventStore: store)
            created.calendar = target
            created.title = event.title
            created.isAllDay = event.isAllDay
            created.startDate = event.start
            created.endDate = Self.storedEnd(event.end, start: event.start, allDay: event.isAllDay)
            created.location = event.location
            created.notes = event.notes
            if let minutes = event.alertMinutesBefore {
                created.addAlarm(EKAlarm(relativeOffset: -TimeInterval(minutes * 60)))
            }
            try save(created)
            return Self.convert(created)
        }
    }

    public func update(id: String, start: Date?, changes: CalendarEventChanges) throws -> CalendarEvent {
        try locked {
            guard let event = find(id: id, start: start) else { throw CalendarError.eventNotFound }
            if let title = changes.title { event.title = title }
            if let newStart = changes.start { event.startDate = newStart }
            if let newEnd = changes.end { event.endDate = Self.storedEnd(newEnd, start: event.startDate, allDay: event.isAllDay) }
            if let location = changes.location { event.location = location.isEmpty ? nil : location }
            if let notes = changes.notes { event.notes = notes.isEmpty ? nil : notes }
            try save(event)
            return Self.convert(event)
        }
    }

    public func delete(id: String, start: Date?) throws {
        try locked {
            guard let event = find(id: id, start: start) else { throw CalendarError.eventNotFound }
            do {
                // Only this occurrence of a repeating event: the least a deletion can take with it.
                try store.remove(event, span: .thisEvent, commit: true)
            } catch {
                throw CalendarError.failed("The calendar couldn't delete the event: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Helpers

    private func save(_ event: EKEvent) throws {
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw CalendarError.failed("The calendar couldn't save the event: \(error.localizedDescription)")
        }
    }

    private func writableCalendar(named name: String?) throws -> EKCalendar {
        let all = store.calendars(for: .event)
        if let name {
            guard let match = all.first(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame && $0.allowsContentModifications })
            else {
                if all.contains(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame }) {
                    throw CalendarError.calendarIsReadOnly(name)
                }
                throw CalendarError.calendarNotFound(name, available: all.filter(\.allowsContentModifications).map(\.title))
            }
            return match
        }
        guard let fallback = store.defaultCalendarForNewEvents ?? all.first(where: \.allowsContentModifications) else {
            throw CalendarError.noDefaultCalendar
        }
        return fallback
    }

    /// The occurrence of event `id` that starts at `start`. Every occurrence of a repeating event shares its identifier, so
    /// the occurrence is found by looking at what is on the calendar around that moment.
    private func find(id: String, start: Date?) -> EKEvent? {
        guard let start else { return store.event(withIdentifier: id) }
        let predicate = store.predicateForEvents(
            withStart: start.addingTimeInterval(-3_600), end: start.addingTimeInterval(3_600), calendars: nil
        )
        return store.events(matching: predicate).first { event in
            event.eventIdentifier == id && abs((event.startDate ?? .distantPast).timeIntervalSince(start)) < 1
        }
    }

    // MARK: All-day events

    // The tools speak of an all-day event's end as the start of the day after its last day. EventKit stores it as the last
    // day itself (Calendar shows and returns it as 23:59:59), so the two are converted at this boundary.

    private static func storedEnd(_ end: Date, start: Date, allDay: Bool) -> Date {
        guard allDay else { return end }
        return max(end.addingTimeInterval(-1), start)
    }

    private static func exclusiveEnd(_ event: EKEvent) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = event.timeZone ?? .current
        let end = event.endDate ?? event.startDate ?? Date()
        let lastDay = calendar.startOfDay(for: end.addingTimeInterval(-1))
        let next = calendar.date(byAdding: .day, value: 1, to: lastDay) ?? end
        return max(next, (event.startDate ?? next).addingTimeInterval(1))
    }

    private static func convert(_ event: EKEvent) -> CalendarEvent {
        CalendarEvent(
            id: event.eventIdentifier ?? event.calendarItemIdentifier,
            title: event.title ?? "(No title)",
            start: event.startDate ?? Date(),
            end: event.isAllDay ? exclusiveEnd(event) : (event.endDate ?? event.startDate ?? Date()),
            isAllDay: event.isAllDay,
            calendar: event.calendar?.title ?? "",
            location: event.location.flatMap { $0.isEmpty ? nil : $0 },
            notes: event.notes.flatMap { $0.isEmpty ? nil : $0 },
            url: event.url?.absoluteString,
            isRecurring: event.hasRecurrenceRules,
            hasAttendees: event.hasAttendees
        )
    }
}
