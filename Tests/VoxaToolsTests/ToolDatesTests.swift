import Foundation
import Testing
@testable import VoxaTools

@Suite("ToolDates")
struct ToolDatesTests {
    static let india = ToolDates(timeZone: TimeZone(identifier: "Asia/Kolkata")!, locale: Locale(identifier: "en_US"))
    private let dates = ToolDatesTests.india

    /// 2026-09-30 15:00 in India, which is 09:30 UTC.
    private let threePM = Date(timeIntervalSince1970: 1_790_760_600)

    @Test("a timestamp with an offset is exactly that moment, whatever the user's zone")
    func withOffset() {
        #expect(dates.parse("2026-09-30T15:00:00+05:30") == .moment(threePM))
        #expect(dates.parse("2026-09-30T09:30:00Z") == .moment(threePM))
        #expect(dates.parse("2026-09-30T04:00:00-05:30") == .moment(threePM))
        #expect(dates.parse("2026-09-30T09:30:00.000Z") == .moment(threePM))
    }

    @Test("a timestamp with no offset is the user's own clock")
    func withoutOffset() {
        #expect(dates.parse("2026-09-30T15:00:00") == .moment(threePM))
        #expect(dates.parse("2026-09-30T15:00") == .moment(threePM))
        #expect(dates.parse("2026-09-30 15:00") == .moment(threePM))
        let pacific = ToolDates(timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        #expect(pacific.parse("2026-09-30T15:00")?.date != threePM)
    }

    @Test("a bare date is a whole day, starting at midnight in the user's zone")
    func dayOnly() {
        let parsed = dates.parse("2026-09-30")
        #expect(parsed?.isDayOnly == true)
        #expect(parsed?.date == Date(timeIntervalSince1970: 1_790_706_600), "midnight in India is 18:30 UTC the day before")
    }

    @Test("things that aren't dates are refused, and so are dates that don't exist", arguments: [
        "", "   ", "tomorrow", "next friday at 3", "2026-13-01", "2026-02-31", "2026-09-31T10:00:00", "15:00", "not a date",
    ])
    func refused(_ text: String) {
        #expect(dates.parse(text) == nil)
    }

    @Test("surrounding whitespace from speech-to-text is ignored")
    func trimmed() {
        #expect(dates.parse("  2026-09-30T15:00:00+05:30\n") == .moment(threePM))
    }

    @Test("dates are written in the user's zone, in the form that is read back")
    func writing() {
        #expect(dates.iso(threePM) == "2026-09-30T15:00:00+05:30")
        #expect(dates.isoDay(threePM) == "2026-09-30")
        #expect(dates.parse(dates.iso(threePM)) == .moment(threePM), "what the model is given can be passed straight back")
    }

    @Test("a span reads the way a person would say it")
    func labels() {
        let end = threePM.addingTimeInterval(30 * 60)
        let same = dates.label(from: threePM, to: end)
        #expect(same.contains("Sep") && same.contains("30") && same.contains("3:00") && same.contains("3:30"))
        #expect(!same.contains("all day"))

        let nextDay = dates.label(from: threePM, to: end.addingTimeInterval(86_400))
        #expect(nextDay.contains("Oct"), "a span across days names both days: \(nextDay)")
    }

    @Test("an all-day event is labelled by its days, with the exclusive end taken into account")
    func allDayLabels() {
        let midnight = dates.parse("2026-09-30")!.date
        let one = dates.label(from: midnight, to: midnight.addingTimeInterval(86_400), allDay: true)
        #expect(one.hasSuffix("(all day)") && !one.contains("–"), Comment(rawValue: one))

        let three = dates.label(from: midnight, to: midnight.addingTimeInterval(3 * 86_400), allDay: true)
        #expect(three.contains("Sep 30") || three.contains("30 Sep"))
        #expect(three.contains("–") && three.hasSuffix("(all day)"), Comment(rawValue: three))
    }
}
