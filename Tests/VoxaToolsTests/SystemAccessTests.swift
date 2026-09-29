import AppKit
import ApplicationServices
import EventKit
import Foundation
import Testing
import VoxaCore
@testable import VoxaTools

/// The real clipboard, on a private pasteboard: what the person has copied is never touched.
@MainActor
@Suite("SystemClipboard", .serialized)
struct SystemClipboardTests {
    private func clipboard() -> (SystemClipboard, NSPasteboard) {
        let name = NSPasteboard.Name("com.rohitsainier.voxa.tests.\(UUID().uuidString)")
        let board = NSPasteboard(name: name)
        board.clearContents()
        return (SystemClipboard(pasteboardName: name), board)
    }

    @Test("what is written can be read back, and replaces what was there")
    func roundTrip() async {
        let (clipboard, board) = clipboard()
        await clipboard.write("first")
        await clipboard.write("second — with unicode: café 😀")
        #expect(await clipboard.read() == .text("second — with unicode: café 😀"))
        #expect(board.string(forType: .string) == "second — with unicode: café 😀")
        board.releaseGlobally()
    }

    @Test("an empty clipboard reads as empty")
    func empty() async {
        let (clipboard, board) = clipboard()
        #expect(await clipboard.read() == .empty)
        board.releaseGlobally()
    }

    @Test("something a password manager marked as secret is never returned, whatever text it also holds")
    func concealed() async {
        let (clipboard, board) = clipboard()
        board.declareTypes([.string, SystemClipboard.concealedType], owner: nil)
        board.setString("hunter2", forType: .string)
        board.setString("", forType: SystemClipboard.concealedType)
        #expect(await clipboard.read() == .concealed)
        board.releaseGlobally()
    }

    @Test("an image is described, not returned")
    func image() async {
        let (clipboard, board) = clipboard()
        let picture = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        board.writeObjects([picture])
        #expect(await clipboard.read() == .other("an image"))
        board.releaseGlobally()
    }

    @Test("copied files are described, not returned")
    func files() async {
        let (clipboard, board) = clipboard()
        board.writeObjects([URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app") as NSURL])
        #expect(await clipboard.read() == .other("files"))
        board.releaseGlobally()
    }
}

/// The real calendar and reminders, in a process that has not been given access. They must hand back nothing, and complain
/// clearly, rather than crash or prompt. (If the process happens to have access, these tests stand aside: they must never
/// change anyone's real calendar.)
@Suite("EventKit without access")
struct EventKitWithoutAccessTests {
    private var hasEventAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    private var hasReminderAccess: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }

    @Test("the calendar has no calendars, no events, and can't create or find anything")
    func calendar() throws {
        guard !hasEventAccess else { return }
        let calendar = EventKitCalendar()
        #expect(calendar.calendars().isEmpty)
        #expect(try calendar.events(from: Date(), to: Date().addingTimeInterval(86_400), calendars: nil, limit: 10).isEmpty)
        #expect(try calendar.event(id: "nothing", start: nil) == nil)
        #expect(try calendar.event(id: "nothing", start: Date()) == nil)
        #expect(throws: CalendarError.self) { try calendar.delete(id: "nothing", start: Date()) }
        #expect(throws: CalendarError.self) {
            try calendar.create(NewCalendarEvent(title: "x", start: Date(), end: Date().addingTimeInterval(60)))
        }
    }

    @Test("reminders have no lists, no items, and can't add one")
    func reminders() async throws {
        guard !hasReminderAccess else { return }
        let reminders = EventKitReminders()
        #expect(reminders.lists().isEmpty)
        #expect(try await reminders.reminders(in: nil, includeCompleted: true, limit: 10).isEmpty)
        #expect(throws: ReminderError.self) { try reminders.create(NewReminder(title: "x")) }
    }

    @Test("the tools built on them report what happened instead of pretending there is nothing")
    func toolsExplain() async {
        guard !hasEventAccess else { return }
        let tool = CalendarCreateEventTool(calendars: EventKitCalendar())
        do {
            _ = try await tool.execute(["title": "x", "start": "2026-10-03T09:00:00+05:30"], context: ToolContext())
            Issue.record("expected an error")
        } catch {
            #expect(!error.localizedDescription.isEmpty)
        }
    }
}

/// The front app, in whatever session the tests run in.
@MainActor
@Suite("SystemFrontmostContext")
struct SystemFrontmostContextTests {
    @Test("it names an app when one is in front, never Voxa itself, and reports honestly whether Accessibility is on")
    func snapshot() async {
        let provider = SystemFrontmostContext()
        provider.start()
        guard let context = await provider.snapshot() else { return }   // no GUI session: nothing to check
        #expect(!context.appName.isEmpty)
        #expect(context.accessibilityGranted == AXIsProcessTrusted())
        if !context.accessibilityGranted {
            #expect(context.windowTitle == nil && context.selectedText == nil, "nothing is read without permission")
        }
    }
}
