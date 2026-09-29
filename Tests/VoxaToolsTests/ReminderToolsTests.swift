import Foundation
import Testing
import VoxaCore
import VoxaPolicy
import VoxaTestSupport
@testable import VoxaTools

@Suite("reminders_create") struct ReminderCreateTests {
    private let reminders = FakeReminders()

    private func tool() -> ReminderCreateTool {
        ReminderCreateTool(reminders: reminders, dates: { CalendarFixture.dates })
    }

    private func run(_ input: JSONValue) async throws -> ToolResult {
        try await tool().execute(input, context: ToolContext())
    }

    @Test("a title alone makes a reminder with no date on the default list")
    func minimal() async throws {
        let result = try await run(["title": "Call the bank"])
        let made = try #require(reminders.created.first)
        #expect(made == NewReminder(title: "Call the bank"))
        #expect(result.plainText.contains("Added the reminder “Call the bank”"))
        #expect(result.notice == "Added a reminder: “Call the bank”")
        #expect(result.provenance == .trusted)
    }

    @Test("a due time is kept exactly, and a bare date is due sometime that day")
    func due() async throws {
        _ = try await run(["title": "A", "due": "2026-10-01T10:00:00+05:30"])
        _ = try await run(["title": "B", "due": "2026-10-01"])
        #expect(reminders.created[0].due == CalendarFixture.at("2026-10-01T10:00:00+05:30"))
        #expect(!reminders.created[0].dueIsDayOnly)
        #expect(reminders.created[1].due == CalendarFixture.day("2026-10-01"))
        #expect(reminders.created[1].dueIsDayOnly)
    }

    @Test("notes, a list (in any case) and a priority are passed on")
    func details() async throws {
        _ = try await run(["title": " Milk ", "notes": " oat ", "list": "groceries", "priority": "high"])
        #expect(reminders.created.first == NewReminder(title: "Milk", notes: "oat", list: "Groceries", priority: .high))
    }

    @Test(
        "bad arguments are refused before anything is added",
        arguments: [
            ["title": "X", "due": "tomorrow morning"], ["title": "X", "priority": "urgent"],
            ["title": "X", "list": "Errands"], ["title": "X", "list": "Shared"], ["title": "   "],
        ] as [[String: JSONValue]]
    )
    func refused(_ input: [String: JSONValue]) async {
        await #expect(throws: ToolInputError.self) { try await run(.object(input)) }
        #expect(reminders.created.isEmpty)
    }

    @Test("an unknown list names the ones that exist and can be added to")
    func listError() async {
        do {
            _ = try await run(["title": "X", "list": "Errands"])
            Issue.record("expected an error")
        } catch let error as ToolInputError {
            #expect(
                error.message.contains("Reminders") && error.message.contains("Groceries")
                    && !error.message.contains("Shared")
            )
        } catch { Issue.record("\(error)") }
    }

    @Test("it is reversible, so the card is a notice, and it shows what will be added")
    func assessment() throws {
        let assessment = try tool().assess([
            "title": "Call the bank", "due": "2026-10-01T10:00:00+05:30", "list": "Groceries", "priority": "low",
        ])
        #expect(assessment.risk == .reversible)
        #expect(assessment.title == "Add a reminder: “Call the bank”")
        #expect(assessment.details.contains(DetailRow("List", "Groceries")))
        #expect(assessment.details.contains(DetailRow("Priority", "low")))
        #expect(assessment.details.contains { $0.label == "Due" && $0.value.contains("10:00") })
        #expect(assessment.targetApp == "Reminders")
        #expect(tool().requiredPermissions == [.reminders])
    }

    @Test("the schema is closed, and priority is one of the four words")
    func schema() {
        let tool = tool()
        #expect(!InputValidator.validate(["title": "X", "priority": "urgent"], against: tool.inputSchema).isEmpty)
        #expect(!InputValidator.validate(["title": "X", "sneaky": true], against: tool.inputSchema).isEmpty)
        #expect(InputValidator.validate(["title": "X", "priority": "medium"], against: tool.inputSchema).isEmpty)
    }
}

@Suite("reminders_list") struct ReminderListToolTests {
    private let reminders = FakeReminders(items: [
        ReminderItem(
            id: "r1",
            title: "Pay rent",
            due: CalendarFixture.at("2026-10-01T09:00:00+05:30"),
            list: "Reminders",
            priority: .high
        ),
        ReminderItem(id: "r2", title: "Buy milk", notes: "oat, not soy", list: "Groceries"),
        ReminderItem(
            id: "r3",
            title: "Book flights",
            due: CalendarFixture.day("2026-09-30"),
            dueIsDayOnly: true,
            list: "Reminders"
        ),
        ReminderItem(id: "r4", title: "File taxes", list: "Reminders", isCompleted: true),
    ])

    private func tool() -> ReminderListTool { ReminderListTool(reminders: reminders, dates: { CalendarFixture.dates }) }

    private func run(_ input: JSONValue) async throws -> ToolResult {
        try await tool().execute(input, context: ToolContext())
    }

    @Test("it lists what is still to do, soonest first, with the undated last")
    func order() async throws {
        let text = try await run([:]).plainText
        #expect(text.hasPrefix("3 reminders:"))
        let flights = try #require(text.range(of: "Book flights"))
        let rent = try #require(text.range(of: "Pay rent"))
        let milk = try #require(text.range(of: "Buy milk"))
        #expect(flights.lowerBound < rent.lowerBound && rent.lowerBound < milk.lowerBound)
        #expect(!text.contains("File taxes"), "done ones are left out unless asked for")
    }

    @Test("due times are given in the form that can be passed back, and a day-only reminder by its date")
    func format()
        async throws {
        let text = try await run([:]).plainText
        #expect(text.contains("due: 2026-10-01T09:00:00+05:30"))
        #expect(text.contains("due: 2026-09-30 ("))
        #expect(text.contains("priority: high"))
        #expect(text.contains("notes: oat, not soy"))
    }

    @Test("done reminders can be included, marked as done")
    func includeCompleted() async throws {
        let text = try await run(["include_completed": true]).plainText
        #expect(text.contains("File taxes (done)"))
        #expect(reminders.queries.last?.includeCompleted == true)
    }

    @Test("a list can be named; an unknown one is an error that names the real ones")
    func listFilter() async throws {
        let text = try await run(["list": "groceries"]).plainText
        #expect(text.contains("Buy milk") && !text.contains("Pay rent"))
        #expect(reminders.queries.last?.list == "Groceries")
        await #expect(throws: ToolInputError.self) { try await run(["list": "Errands"]) }
    }

    @Test("the limit caps the list and says there is more")
    func limit() async throws {
        let text = try await run(["limit": 2]).plainText
        #expect(text.hasPrefix("2 reminders:"))
        #expect(text.contains("There are more reminders"))
        #expect(reminders.queries.last?.limit == 3)
    }

    @Test("what comes back is untrusted, and an empty list is a plain trusted sentence")
    func provenance() async throws {
        #expect(try await run([:]).provenance == .untrusted(source: "reminders"))
        let empty = try await ReminderListTool(reminders: FakeReminders(), dates: { CalendarFixture.dates }).execute(
            [:],
            context: ToolContext()
        )
        #expect(empty.plainText == "No reminders to show.")
        #expect(empty.provenance == .trusted)
    }

    @Test("it is read-only and needs Reminders access")
    func metadata() {
        #expect(tool().baselineRisk == .readOnly)
        #expect(tool().requiredPermissions == [.reminders])
    }
}
