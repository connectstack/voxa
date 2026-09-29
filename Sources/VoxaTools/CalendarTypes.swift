import Foundation
import VoxaCore

/// One calendar the user has (Home, Work, a subscribed holiday calendar).
public struct CalendarInfo: Sendable, Equatable {
    public var name: String
    /// Whether events can be added to it. Subscribed and holiday calendars are read-only.
    public var allowsModifications: Bool

    public init(name: String, allowsModifications: Bool = true) {
        self.name = name
        self.allowsModifications = allowsModifications
    }
}

/// An event as tools see it: plain values, nothing that belongs to EventKit.
public struct CalendarEvent: Sendable, Equatable {
    /// EventKit's identifier. Every occurrence of a repeating event shares it, so an occurrence is named by `id` and `start`.
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var calendar: String
    public var location: String?
    public var notes: String?
    public var url: String?
    public var isRecurring: Bool
    /// Whether other people are invited. Changing such an event can notify them.
    public var hasAttendees: Bool

    public init(
        id: String,
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        calendar: String = "Calendar",
        location: String? = nil,
        notes: String? = nil,
        url: String? = nil,
        isRecurring: Bool = false,
        hasAttendees: Bool = false
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendar = calendar
        self.location = location
        self.notes = notes
        self.url = url
        self.isRecurring = isRecurring
        self.hasAttendees = hasAttendees
    }
}

/// An event to add.
public struct NewCalendarEvent: Sendable, Equatable {
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    /// The calendar's name, or nil for the user's default calendar for new events.
    public var calendar: String?
    public var location: String?
    public var notes: String?
    public var alertMinutesBefore: Int?

    public init(
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        calendar: String? = nil,
        location: String? = nil,
        notes: String? = nil,
        alertMinutesBefore: Int? = nil
    ) {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendar = calendar
        self.location = location
        self.notes = notes
        self.alertMinutesBefore = alertMinutesBefore
    }
}

/// What to change on an existing event. Only the fields that are set change.
public struct CalendarEventChanges: Sendable, Equatable {
    public var title: String?
    public var start: Date?
    public var end: Date?
    public var location: String?
    public var notes: String?

    public init(title: String? = nil, start: Date? = nil, end: Date? = nil, location: String? = nil, notes: String? = nil) {
        self.title = title
        self.start = start
        self.end = end
        self.location = location
        self.notes = notes
    }

    public var isEmpty: Bool {
        title == nil && start == nil && end == nil && location == nil && notes == nil
    }
}

public enum CalendarError: Error, Sendable, Equatable, LocalizedError {
    /// There is no calendar by that name. Carries the ones that exist, so the model can pick one.
    case calendarNotFound(String, available: [String])
    case calendarIsReadOnly(String)
    case noDefaultCalendar
    case eventNotFound
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .calendarNotFound(let name, let available):
            "There is no calendar named '\(name)'. The calendars are: \(available.joined(separator: ", "))."
        case .calendarIsReadOnly(let name):
            "The calendar '\(name)' is read-only, so nothing can be added to it."
        case .noDefaultCalendar:
            "There is no default calendar for new events. Name one."
        case .eventNotFound:
            "No event matches that id and start time."
        case .failed(let reason):
            reason
        }
    }
}

/// The user's calendars, behind a protocol so the tools are tested without EventKit.
///
/// Synchronous on purpose: EventKit's own calls are, and a tool's `assess` (which can't be `async`) has to read the event it
/// is about to change or delete so the confirmation card shows what will really happen.
public protocol CalendarAccessing: Sendable {
    func calendars() -> [CalendarInfo]
    func events(from start: Date, to end: Date, calendars names: [String]?, limit: Int) throws -> [CalendarEvent]
    /// The occurrence of event `id` that starts at `start` (any occurrence if `start` is nil), or nil if there is none.
    func event(id: String, start: Date?) throws -> CalendarEvent?
    func create(_ event: NewCalendarEvent) throws -> CalendarEvent
    func update(id: String, start: Date?, changes: CalendarEventChanges) throws -> CalendarEvent
    func delete(id: String, start: Date?) throws
}
