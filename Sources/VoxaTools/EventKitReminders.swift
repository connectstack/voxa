import EventKit
import Foundation
import VoxaCore

/// The user's real reminders, through EventKit. Like `EventKitCalendar`, it assumes access has been granted first.
public final class EventKitReminders: RemindersAccessing, @unchecked Sendable {
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

    public func lists() -> [ReminderListInfo] {
        locked {
            store.calendars(for: .reminder).map { ReminderListInfo(name: $0.title, allowsModifications: $0.allowsContentModifications) }
        }
    }

    public func reminders(in list: String?, includeCompleted: Bool, limit: Int) async throws -> [ReminderItem] {
        let predicate: NSPredicate = locked {
            let selected = list.map { name in
                store.calendars(for: .reminder).filter { $0.title.caseInsensitiveCompare(name) == .orderedSame }
            }
            return includeCompleted
                ? store.predicateForReminders(in: selected)
                : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: selected)
        }
        // EventKit answers on its own queue with objects that must not leave it, so they are turned into plain values there.
        let items: [ReminderItem] = await withCheckedContinuation { continuation in
            locked {
                _ = store.fetchReminders(matching: predicate) { found in
                    continuation.resume(returning: (found ?? []).map(Self.convert))
                }
            }
        }
        // Soonest due first; the ones with no date come last.
        let sorted = items.sorted { lhs, rhs in
            switch (lhs.due, rhs.due) {
            case (let left?, let right?): left < right
            case (.some, .none): true
            default: false
            }
        }
        return Array(sorted.prefix(limit))
    }

    public func create(_ reminder: NewReminder) throws -> ReminderItem {
        try locked {
            let created = EKReminder(eventStore: store)
            created.calendar = try writableList(named: reminder.list)
            created.title = reminder.title
            created.notes = reminder.notes
            created.priority = Self.storedPriority(reminder.priority)

            if let due = reminder.due {
                let calendar = Calendar.current
                let parts: Set<Calendar.Component> = reminder.dueIsDayOnly ? [.year, .month, .day] : [.year, .month, .day, .hour, .minute]
                var components = calendar.dateComponents(parts, from: due)
                components.calendar = calendar
                if !reminder.dueIsDayOnly {
                    components.timeZone = calendar.timeZone
                    // A due time on its own doesn't make Reminders notify; an alarm at that moment does.
                    created.addAlarm(EKAlarm(absoluteDate: due))
                }
                created.dueDateComponents = components
            }
            do {
                try store.save(created, commit: true)
            } catch {
                throw ReminderError.failed("Reminders couldn't save the reminder: \(error.localizedDescription)")
            }
            return Self.convert(created)
        }
    }

    // MARK: Helpers

    private func writableList(named name: String?) throws -> EKCalendar {
        let all = store.calendars(for: .reminder)
        if let name {
            guard let match = all.first(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame && $0.allowsContentModifications })
            else {
                if all.contains(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame }) {
                    throw ReminderError.listIsReadOnly(name)
                }
                throw ReminderError.listNotFound(name, available: all.filter(\.allowsContentModifications).map(\.title))
            }
            return match
        }
        guard let fallback = store.defaultCalendarForNewReminders() ?? all.first(where: \.allowsContentModifications) else {
            throw ReminderError.noDefaultList
        }
        return fallback
    }

    /// EventKit's own scale: 1 to 4 is high, 5 medium, 6 to 9 low, 0 none.
    private static func storedPriority(_ priority: ReminderPriority) -> Int {
        switch priority {
        case .none: 0
        case .high: 1
        case .medium: 5
        case .low: 9
        }
    }

    private static func priority(from stored: Int) -> ReminderPriority {
        switch stored {
        case 1...4: .high
        case 5: .medium
        case 6...9: .low
        default: .none
        }
    }

    private static func convert(_ reminder: EKReminder) -> ReminderItem {
        var due: Date?
        var dayOnly = false
        if let components = reminder.dueDateComponents {
            var calendar = components.calendar ?? Calendar(identifier: .gregorian)
            if let zone = components.timeZone { calendar.timeZone = zone }
            due = calendar.date(from: components)
            dayOnly = components.hour == nil
        }
        return ReminderItem(
            id: reminder.calendarItemIdentifier,
            title: reminder.title ?? "(No title)",
            due: due,
            dueIsDayOnly: dayOnly,
            notes: reminder.notes.flatMap { $0.isEmpty ? nil : $0 },
            list: reminder.calendar?.title ?? "",
            priority: priority(from: reminder.priority),
            isCompleted: reminder.isCompleted
        )
    }
}
