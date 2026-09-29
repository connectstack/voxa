import Foundation
import Testing
import VoxaCore
import VoxaPolicy
import VoxaTestSupport
@testable import VoxaTools

/// Shared by the calendar tool suites: a calendar with a few events, and a fixed "now" in a fixed time zone.
enum CalendarFixture {
    static let dates = ToolDatesTests.india
    /// 2026-09-30 09:00 in India.
    static let now = Date(timeIntervalSince1970: 1_790_739_000)

    static func at(_ iso: String) -> Date {
        guard case .moment(let date)? = dates.parse(iso) else { fatalError("bad fixture date \(iso)") }
        return date
    }

    static func day(_ iso: String) -> Date { dates.parse(iso)!.date }

    static func events() -> [CalendarEvent] {
        [
            CalendarEvent(
                id: "evt-dentist",
                title: "Dentist",
                start: at("2026-09-30T15:00:00+05:30"),
                end: at("2026-09-30T15:30:00+05:30"),
                calendar: "Home",
                location: "12 Main St"
            ),
            CalendarEvent(
                id: "evt-standup",
                title: "Standup",
                start: at("2026-10-01T10:00:00+05:30"),
                end: at("2026-10-01T10:15:00+05:30"),
                calendar: "Work",
                notes: "Zoom: https://example.com/j/123",
                isRecurring: true,
                hasAttendees: true
            ),
            CalendarEvent(
                id: "evt-holiday",
                title: "Gandhi Jayanti",
                start: day("2026-10-02"),
                end: day("2026-10-03"),
                isAllDay: true,
                calendar: "Holidays"
            ),
            CalendarEvent(
                id: "evt-later",
                title: "Conference",
                start: at("2026-11-20T09:00:00+05:30"),
                end: at("2026-11-20T17:00:00+05:30"),
                calendar: "Work"
            ),
        ]
    }
}

@Suite("calendar_list_events") struct CalendarListEventsTests {
    private let calendar = FakeCalendar(events: CalendarFixture.events())

    private func tool() -> CalendarListEventsTool {
        CalendarListEventsTool(calendars: calendar, dates: { CalendarFixture.dates }, now: { CalendarFixture.now })
    }

    private func run(_ input: JSONValue) async throws -> ToolResult {
        try await tool().execute(input, context: ToolContext())
    }

    @Test("with no arguments it lists the next seven days, soonest first, and says how many")
    func defaultRange()
        async throws {
        let result = try await run([:])
        #expect(!result.isError)
        #expect(result.plainText.hasPrefix("3 events from"))
        let text = result.plainText
        let dentist = try #require(text.range(of: "Dentist"))
        let standup = try #require(text.range(of: "Standup"))
        #expect(dentist.lowerBound < standup.lowerBound)
        #expect(!text.contains("Conference"), "that is seven weeks away")
        #expect(calendar.queries.first?.start == CalendarFixture.now)
        #expect(calendar.queries.first?.end == CalendarFixture.now.addingTimeInterval(7 * 86_400))
    }

    @Test("each event carries the id and start that an update or delete needs")
    func eventFormat() async throws {
        let text = try await run([:]).plainText
        #expect(text.contains("1. Dentist —"))
        #expect(text.contains("start: 2026-09-30T15:00:00+05:30"))
        #expect(text.contains("end: 2026-09-30T15:30:00+05:30"))
        #expect(text.contains("id: evt-dentist"))
        #expect(text.contains("location: 12 Main St"))
        #expect(text.contains("repeats: yes") && text.contains("other people invited: yes"))
        #expect(text.contains("notes: Zoom: https://example.com/j/123"))
    }

    @Test("an all-day event is given by dates: its last day is inclusive")
    func allDay() async throws {
        let text = try await run(["start": "2026-10-02", "end": "2026-10-02"]).plainText
        #expect(text.contains("Gandhi Jayanti"))
        #expect(text.contains("start: 2026-10-02"))
        #expect(text.contains("end: 2026-10-02"))
        #expect(text.contains("all day: yes"))
    }

    @Test("a bare date as the end covers the whole of that day")
    func dateEndCoversTheDay() async throws {
        let text = try await run(["start": "2026-09-30T00:00:00+05:30", "end": "2026-09-30"]).plainText
        #expect(text.contains("Dentist"), "the 3 PM event is inside 'through the 30th'")
        #expect(!text.contains("Standup"))
    }

    @Test("what comes back is data written by other people, so it is untrusted")
    func untrusted() async throws {
        let result = try await run([:])
        #expect(result.provenance == .untrusted(source: "calendar events"))
        #expect(result.notice == "Read your calendar (3 events)")
    }

    @Test("an empty range says so plainly and carries no outside data")
    func empty() async throws {
        let result = try await run(["start": "2027-01-01T00:00:00+05:30", "end": "2027-01-02T00:00:00+05:30"])
        #expect(result.plainText.hasPrefix("No events from"))
        #expect(result.provenance == .trusted)
    }

    @Test("a calendar can be named, in any case, and an unknown name lists the real ones")
    func calendarFilter()
        async throws {
        let text = try await run(["calendar": "work"]).plainText
        #expect(text.contains("Standup") && !text.contains("Dentist"))
        #expect(calendar.queries.last?.calendars == ["Work"])

        await #expect(throws: ToolInputError.self) { try await run(["calendar": "Gym"]) }
        do { _ = try await run(["calendar": "Gym"]) } catch let error as ToolInputError {
            #expect(error.message.contains("Home") && error.message.contains("Work"), Comment(rawValue: error.message))
        }
    }

    @Test("the limit caps the list and the result says there is more")
    func limit() async throws {
        let text = try await run(["limit": 1]).plainText
        #expect(text.hasPrefix("1 event from"))
        #expect(text.contains("Dentist") && !text.contains("Standup"))
        #expect(text.contains("There are more events in this range"))
        #expect(calendar.queries.last?.limit == 2, "one extra is asked for, to know whether there is more")
    }

    @Test(
        "bad ranges are refused with something the model can act on",
        arguments: [
            ["start": "tomorrow"], ["end": "soon"],
            ["start": "2026-10-05T00:00:00+05:30", "end": "2026-10-01T00:00:00+05:30"],
            ["start": "2026-01-01", "end": "2026-12-31"],
        ] as [[String: JSONValue]]
    )
    func badRanges(_ input: [String: JSONValue]) async {
        await #expect(throws: ToolInputError.self) { try await run(.object(input)) }
    }

    @Test("it is read-only and needs Calendar access")
    func metadata() throws {
        #expect(tool().baselineRisk == .readOnly)
        #expect(tool().requiredPermissions == [.calendars])
        let assessment = try tool().assess(["calendar": "Work"])
        #expect(assessment.risk == .readOnly)
        #expect(assessment.details.contains(DetailRow("Calendar", "Work")))
    }

    @Test("a failure from the system reaches the caller instead of looking like an empty calendar")
    func failure() async {
        struct Broken: Error {}
        calendar.failure = Broken()
        await #expect(throws: Broken.self) { try await run([:]) }
    }
}
