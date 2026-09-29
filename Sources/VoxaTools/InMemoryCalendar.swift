import Foundation
import os

/// A calendar that lives in memory: it stores what the tools create, applies their changes, and remembers every call.
/// Used by tests, and by Debug builds of the app that are run against sample data instead of the user's real calendar.
public final class InMemoryCalendar: CalendarAccessing, @unchecked Sendable {
    private struct State {
        var calendars: [CalendarInfo]
        var events: [CalendarEvent]
        var nextID = 1
        var created: [NewCalendarEvent] = []
        var updates: [Update] = []
        var deleted: [String] = []
        var queries: [Query] = []
        var failure: (any Error)?
    }

    public struct Update: Sendable, Equatable {
        public var id: String
        public var start: Date?
        public var changes: CalendarEventChanges
    }

    public struct Query: Sendable, Equatable {
        public var start: Date
        public var end: Date
        public var calendars: [String]?
        public var limit: Int
    }

    private let state: OSAllocatedUnfairLock<State>

    public init(
        calendars: [CalendarInfo] = [
            CalendarInfo(name: "Home"), CalendarInfo(name: "Work"), CalendarInfo(name: "Holidays", allowsModifications: false),
        ],
        events: [CalendarEvent] = []
    ) {
        state = OSAllocatedUnfairLock(initialState: State(calendars: calendars, events: events))
    }

    public var events: [CalendarEvent] { state.withLock { $0.events } }
    public var created: [NewCalendarEvent] { state.withLock { $0.created } }
    public var updates: [Update] { state.withLock { $0.updates } }
    public var deleted: [String] { state.withLock { $0.deleted } }
    public var queries: [Query] { state.withLock { $0.queries } }

    /// Makes every later call that can fail throw this error.
    public var failure: (any Error)? {
        get { state.withLock { $0.failure } }
        set { state.withLock { $0.failure = newValue } }
    }

    /// Replaces an event's title, as if another person had renamed it in a shared calendar.
    public func injectTitle(_ title: String, forID id: String) {
        state.withLock { state in
            if let index = state.events.firstIndex(where: { $0.id == id }) { state.events[index].title = title }
        }
    }

    public func calendars() -> [CalendarInfo] { state.withLock { $0.calendars } }

    public func events(from start: Date, to end: Date, calendars names: [String]?, limit: Int) throws -> [CalendarEvent] {
        try state.withLock { state in
            if let failure = state.failure { throw failure }
            state.queries.append(Query(start: start, end: end, calendars: names, limit: limit))
            return state.events
                .filter { $0.start < end && $0.end > start }
                .filter { event in names.map { $0.contains { $0.caseInsensitiveCompare(event.calendar) == .orderedSame } } ?? true }
                .sorted { $0.start < $1.start }
                .prefix(limit)
                .map { $0 }
        }
    }

    public func event(id: String, start: Date?) throws -> CalendarEvent? {
        try state.withLock { state in
            if let failure = state.failure { throw failure }
            return state.events.first { $0.id == id && (start == nil || $0.start == start) }
        }
    }

    public func create(_ event: NewCalendarEvent) throws -> CalendarEvent {
        try state.withLock { state in
            if let failure = state.failure { throw failure }
            let calendar = event.calendar ?? state.calendars.first { $0.allowsModifications }?.name ?? "Home"
            let made = CalendarEvent(
                id: "evt-\(state.nextID)",
                title: event.title,
                start: event.start,
                end: event.end,
                isAllDay: event.isAllDay,
                calendar: calendar,
                location: event.location,
                notes: event.notes
            )
            state.nextID += 1
            state.created.append(event)
            state.events.append(made)
            return made
        }
    }

    public func update(id: String, start: Date?, changes: CalendarEventChanges) throws -> CalendarEvent {
        try state.withLock { state in
            if let failure = state.failure { throw failure }
            guard let index = state.events.firstIndex(where: { $0.id == id && (start == nil || $0.start == start) }) else {
                throw CalendarError.eventNotFound
            }
            state.updates.append(Update(id: id, start: start, changes: changes))
            var event = state.events[index]
            if let title = changes.title { event.title = title }
            if let newStart = changes.start { event.start = newStart }
            if let newEnd = changes.end { event.end = newEnd }
            if let location = changes.location { event.location = location.isEmpty ? nil : location }
            if let notes = changes.notes { event.notes = notes.isEmpty ? nil : notes }
            state.events[index] = event
            return event
        }
    }

    public func delete(id: String, start: Date?) throws {
        try state.withLock { state in
            if let failure = state.failure { throw failure }
            guard let index = state.events.firstIndex(where: { $0.id == id && (start == nil || $0.start == start) }) else {
                throw CalendarError.eventNotFound
            }
            state.deleted.append(id)
            state.events.remove(at: index)
        }
    }
}
