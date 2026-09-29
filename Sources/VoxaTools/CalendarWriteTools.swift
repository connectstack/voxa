import Foundation
import VoxaCore

/// Adds an event. Adding is undoable (the user can delete it), so it runs with a notice; it never invites anyone.
public struct CalendarCreateEventTool: TypedTool {
    public struct Input: ToolInput {
        public let title: String
        public let start: String
        public let end: String?
        public let durationMinutes: Int?
        // An optional so that "not given" is different from false; the model may leave it out.
        // swiftlint:disable:next discouraged_optional_boolean
        public let allDay: Bool?
        public let calendar: String?
        public let location: String?
        public let notes: String?
        public let alertMinutesBefore: Int?

        enum CodingKeys: String, CodingKey {
            case title, start, end, calendar, location, notes
            case durationMinutes = "duration_minutes"
            case allDay = "all_day"
            case alertMinutesBefore = "alert_minutes_before"
        }
    }

    public let name = "calendar_create_event"
    public let summary = """
        Adds an event to the user's calendar. Give the title and start (an ISO 8601 timestamp with a UTC offset). Give an end \
        or duration_minutes (default one hour), or set all_day for an all-day event. Use it for "put dinner with Sam on \
        Friday at 7 in my calendar". It doesn't invite anyone. To change or remove an existing event use \
        calendar_update_event or calendar_delete_event.
        """
    public let inputSchema = Schema.object(
        [
            "title": Schema.string(
                "The event's title.",
                minLength: 1,
                maxLength: CalendarToolSupport.maxTitleCharacters
            ),
            "start": Schema.string("When it starts. \(ToolDates.expected). For an all-day event a date is enough."),
            "end": Schema.string(
                "When it ends, in the same form. For an all-day event, its last day. Don't combine with duration_minutes."
            ),
            "duration_minutes": Schema.integer("How long it lasts. Default 60.", minimum: 1, maximum: 20_160),
            "all_day": Schema.boolean("True for an all-day event."),
            "calendar": Schema.string("The calendar's name. Default: the user's default calendar.", maxLength: 100),
            "location": Schema.string("Where it is.", maxLength: 200),
            "notes": Schema.string("Notes to attach.", maxLength: 2000),
            "alert_minutes_before": Schema.integer(
                "Alert this many minutes before it starts.",
                minimum: 0,
                maximum: 10_080
            ),
        ],
        required: ["title", "start"]
    )
    public let baselineRisk = RiskLevel.reversible
    public let requiredPermissions: Set<PermissionKind> = [.calendars]

    private let calendars: any CalendarAccessing
    private let dates: @Sendable () -> ToolDates

    public init(calendars: any CalendarAccessing, dates: @escaping @Sendable () -> ToolDates = { .current }) {
        self.calendars = calendars
        self.dates = dates
    }

    private func draft(_ input: Input, dates: ToolDates) throws -> (event: NewCalendarEvent, calendar: String) {
        let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ToolInputError("The title is empty.") }
        let span = try CalendarToolSupport.span(
            start: input.start,
            end: input.end,
            durationMinutes: input.durationMinutes,
            allDay: input.allDay ?? false,
            dates: dates
        )
        let chosen = try CalendarToolSupport.resolveCalendar(
            input.calendar,
            in: calendars.calendars(),
            forWriting: true
        )
        let event = NewCalendarEvent(
            title: title,
            start: span.start,
            end: span.end,
            isAllDay: span.isAllDay,
            calendar: chosen?.name,
            location: input.location?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            notes: input.notes?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            alertMinutesBefore: input.alertMinutesBefore
        )
        return (event, chosen?.name ?? "your default calendar")
    }

    public func assess(_ input: Input) throws -> ToolAssessment {
        let dates = dates()
        let (event, calendar) = try draft(input, dates: dates)
        let when = dates.label(from: event.start, to: event.end, allDay: event.isAllDay)

        var details = [DetailRow("Title", event.title), DetailRow("When", when), DetailRow("Calendar", calendar)]
        if let location = event.location { details.append(DetailRow("Where", location)) }
        if let alert = event.alertMinutesBefore { details.append(DetailRow("Alert", "\(alert) minutes before")) }
        return ToolAssessment(
            risk: .reversible,
            title: "Add “\(CalendarToolSupport.shortTitle(event.title))” to your calendar",
            summary: "Adds an event on \(when) to \(calendar).",
            details: details,
            targetApp: "Calendar"
        )
    }

    public func run(_ input: Input, context: ToolContext) async throws -> ToolResult {
        let dates = dates()
        let (draft, _) = try draft(input, dates: dates)
        let created = try calendars.create(draft)
        let when = dates.label(from: created.start, to: created.end, allDay: created.isAllDay)
        return .text(
            "Added “\(draft.title)” on \(when) to the \(created.calendar) calendar. "
                + CalendarToolSupport.reference(created, dates: dates),
            notice: "Added “\(CalendarToolSupport.shortTitle(draft.title))” to your calendar"
        )
    }
}

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }

// MARK: - Changing an existing event

/// Changes an event. It can move a meeting other people are in, so it always asks first.
public struct CalendarUpdateEventTool: TypedTool {
    public struct Input: ToolInput {
        public let id: String
        public let start: String
        public let title: String?
        public let newStart: String?
        public let newEnd: String?
        public let location: String?
        public let notes: String?

        enum CodingKeys: String, CodingKey {
            case id, start, title, location, notes
            case newStart = "new_start"
            case newEnd = "new_end"
        }
    }

    public let name = "calendar_update_event"
    public let summary = """
        Changes an existing calendar event: its title, when it happens, its location or notes. Give the event's id and its \
        current start exactly as calendar_list_events returned them, then only what should change. Use new_start to move it \
        (its length is kept unless you also give new_end). For a repeating event only that one occurrence changes.
        """
    public let inputSchema = Schema.object(
        [
            "id": Schema.string("The event's id, from calendar_list_events.", minLength: 1, maxLength: 300),
            "start": Schema.string(
                "The event's current start, from calendar_list_events (identifies which occurrence)."
            ),
            "title": Schema.string("A new title.", minLength: 1, maxLength: CalendarToolSupport.maxTitleCharacters),
            "new_start": Schema.string("When it should start instead. \(ToolDates.expected)."),
            "new_end": Schema.string("When it should end instead, in the same form."),
            "location": Schema.string("A new location.", maxLength: 200),
            "notes": Schema.string("New notes, replacing the old ones.", maxLength: 2000),
        ],
        required: ["id", "start"]
    )
    public let baselineRisk = RiskLevel.sensitive
    public let requiredPermissions: Set<PermissionKind> = [.calendars]

    private let calendars: any CalendarAccessing
    private let dates: @Sendable () -> ToolDates

    public init(calendars: any CalendarAccessing, dates: @escaping @Sendable () -> ToolDates = { .current }) {
        self.calendars = calendars
        self.dates = dates
    }

    private struct Plan {
        var current: CalendarEvent
        var changes: CalendarEventChanges
        var occurrence: Date
    }

    private func plan(_ input: Input, dates: ToolDates) throws -> Plan {
        let occurrence = try CalendarToolSupport.parse(input.start, argument: "start", dates: dates).date
        guard let current = try calendars.event(id: input.id, start: occurrence) else {
            throw ToolInputError(
                "No event has that id at that start. Use calendar_list_events to find it, and pass its id and start exactly."
            )
        }
        var changes = CalendarEventChanges(
            title: input.title?.trimmingCharacters(in: .whitespacesAndNewlines),
            location: input.location?.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: input.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if changes.title?.isEmpty == true { throw ToolInputError("The new title is empty.") }

        if input.newStart != nil || input.newEnd != nil {
            let length = current.end.timeIntervalSince(current.start)
            let newStart = try input.newStart.map {
                try CalendarToolSupport.parse($0, argument: "new_start", dates: dates).date
            }
            let newEnd = try input.newEnd.map {
                try CalendarToolSupport.parse($0, argument: "new_end", dates: dates).date
            }
            let start = newStart ?? current.start
            let end = newEnd ?? (newStart != nil ? start.addingTimeInterval(length) : current.end)
            guard end > start else { throw ToolInputError("The new end must be after the new start.") }
            changes.start = start
            changes.end = end
        }
        guard !changes.isEmpty else {
            throw ToolInputError("Nothing to change: give a title, new_start, new_end, location or notes.")
        }
        return Plan(current: current, changes: changes, occurrence: occurrence)
    }

    public func assess(_ input: Input) throws -> ToolAssessment {
        let dates = dates()
        let plan = try plan(input, dates: dates)
        let event = plan.current
        let was = dates.label(from: event.start, to: event.end, allDay: event.isAllDay)

        var details = [DetailRow("Event", event.title), DetailRow("Now", was), DetailRow("Calendar", event.calendar)]
        if let title = plan.changes.title { details.append(DetailRow("New title", title)) }
        if let start = plan.changes.start, let end = plan.changes.end {
            details.append(DetailRow("New time", dates.label(from: start, to: end, allDay: event.isAllDay)))
        }
        if let location = plan.changes.location {
            details.append(DetailRow("New location", location.isEmpty ? "(none)" : location))
        }
        if plan.changes.notes != nil { details.append(DetailRow("Notes", "Replaced")) }

        var reasons = ["Changes an event in your calendar."]
        if event.hasAttendees {
            reasons.append("Other people are invited to this event, so changing it may notify them.")
        }
        if event.isRecurring { reasons.append("This event repeats; only this occurrence changes.") }
        return ToolAssessment(
            risk: .sensitive,
            title: "Change “\(CalendarToolSupport.shortTitle(event.title))”",
            summary: "Changes the event “\(CalendarToolSupport.shortTitle(event.title))” on \(was).",
            details: details,
            targetApp: "Calendar",
            reasons: reasons
        )
    }

    public func run(_ input: Input, context: ToolContext) async throws -> ToolResult {
        let dates = dates()
        let plan = try plan(input, dates: dates)
        let updated = try calendars.update(id: input.id, start: plan.occurrence, changes: plan.changes)

        // Only what the model itself asked for is repeated: the event's stored title is other people's text.
        var parts: [String] = []
        if let title = plan.changes.title { parts.append("renamed to “\(title)”") }
        if updated.start != plan.current.start || updated.end != plan.current.end {
            parts.append("now \(dates.label(from: updated.start, to: updated.end, allDay: updated.isAllDay))")
        }
        if plan.changes.location != nil { parts.append("location changed") }
        if plan.changes.notes != nil { parts.append("notes replaced") }
        return .text(
            "Updated the event: \(parts.joined(separator: ", ")). \(CalendarToolSupport.reference(updated, dates: dates))",
            notice: "Updated the event"
        )
    }
}

// MARK: - Removing an event

/// Deletes an event. Always asks: it can't be undone from here.
public struct CalendarDeleteEventTool: TypedTool {
    public struct Input: ToolInput {
        public let id: String
        public let start: String
    }

    public let name = "calendar_delete_event"
    public let summary = """
        Deletes a calendar event. Give the event's id and its start exactly as calendar_list_events returned them. For a \
        repeating event only that one occurrence is deleted. The user is always asked first.
        """
    public let inputSchema = Schema.object(
        [
            "id": Schema.string("The event's id, from calendar_list_events.", minLength: 1, maxLength: 300),
            "start": Schema.string("The event's start, from calendar_list_events (identifies which occurrence)."),
        ],
        required: ["id", "start"]
    )
    public let baselineRisk = RiskLevel.sensitive
    public let requiredPermissions: Set<PermissionKind> = [.calendars]

    private let calendars: any CalendarAccessing
    private let dates: @Sendable () -> ToolDates

    public init(calendars: any CalendarAccessing, dates: @escaping @Sendable () -> ToolDates = { .current }) {
        self.calendars = calendars
        self.dates = dates
    }

    private func find(_ input: Input, dates: ToolDates) throws -> (event: CalendarEvent, occurrence: Date) {
        let occurrence = try CalendarToolSupport.parse(input.start, argument: "start", dates: dates).date
        guard let event = try calendars.event(id: input.id, start: occurrence) else {
            throw ToolInputError(
                "No event has that id at that start. Use calendar_list_events to find it, and pass its id and start exactly."
            )
        }
        return (event, occurrence)
    }

    public func assess(_ input: Input) throws -> ToolAssessment {
        let dates = dates()
        let (event, _) = try find(input, dates: dates)
        let when = dates.label(from: event.start, to: event.end, allDay: event.isAllDay)

        var reasons = ["Deletes an event from your calendar."]
        if event.hasAttendees {
            reasons.append("Other people are invited to this event, so deleting it may notify them.")
        }
        if event.isRecurring { reasons.append("This event repeats; only this occurrence is deleted.") }
        return ToolAssessment(
            risk: .sensitive,
            title: "Delete “\(CalendarToolSupport.shortTitle(event.title))”",
            summary: "Deletes the event “\(CalendarToolSupport.shortTitle(event.title))” on \(when).",
            details: [DetailRow("Event", event.title), DetailRow("When", when), DetailRow("Calendar", event.calendar)],
            targetApp: "Calendar",
            reasons: reasons
        )
    }

    public func run(_ input: Input, context: ToolContext) async throws -> ToolResult {
        let dates = dates()
        let (_, occurrence) = try find(input, dates: dates)
        try calendars.delete(id: input.id, start: occurrence)
        return .text("Deleted the event.", notice: "Deleted the event")
    }
}
