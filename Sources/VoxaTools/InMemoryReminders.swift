import Foundation
import os

/// Reminders that live in memory, for tests and for sample-data runs.
public final class InMemoryReminders: RemindersAccessing, @unchecked Sendable {
    private struct State {
        var lists: [ReminderListInfo]
        var items: [ReminderItem]
        var nextID = 1
        var created: [NewReminder] = []
        var queries: [Query] = []
        var failure: (any Error)?
    }

    public struct Query: Sendable, Equatable {
        public var list: String?
        public var includeCompleted: Bool
        public var limit: Int
    }

    private let state: OSAllocatedUnfairLock<State>

    public init(
        lists: [ReminderListInfo] = [
            ReminderListInfo(name: "Reminders"),
            ReminderListInfo(name: "Groceries"),
            ReminderListInfo(name: "Shared", allowsModifications: false),
        ],
        items: [ReminderItem] = []
    ) {
        state = OSAllocatedUnfairLock(initialState: State(lists: lists, items: items))
    }

    public var created: [NewReminder] { state.withLock { $0.created } }
    public var queries: [Query] { state.withLock { $0.queries } }
    public var items: [ReminderItem] { state.withLock { $0.items } }

    public var failure: (any Error)? {
        get { state.withLock { $0.failure } }
        set { state.withLock { $0.failure = newValue } }
    }

    public func lists() -> [ReminderListInfo] { state.withLock { $0.lists } }

    public func reminders(in list: String?, includeCompleted: Bool, limit: Int) async throws -> [ReminderItem] {
        try state.withLock { state in
            if let failure = state.failure { throw failure }
            state.queries.append(Query(list: list, includeCompleted: includeCompleted, limit: limit))
            return state.items
                .filter { includeCompleted || !$0.isCompleted }
                .filter { item in list.map { $0.caseInsensitiveCompare(item.list) == .orderedSame } ?? true }
                .sorted { lhs, rhs in
                    switch (lhs.due, rhs.due) {
                    case (let left?, let right?): left < right
                    case (.some, .none): true
                    default: false
                    }
                }
                .prefix(limit)
                .map { $0 }
        }
    }

    public func create(_ reminder: NewReminder) throws -> ReminderItem {
        try state.withLock { state in
            if let failure = state.failure { throw failure }
            let item = ReminderItem(
                id: "rem-\(state.nextID)",
                title: reminder.title,
                due: reminder.due,
                dueIsDayOnly: reminder.dueIsDayOnly,
                notes: reminder.notes,
                list: reminder.list ?? state.lists.first { $0.allowsModifications }?.name ?? "Reminders",
                priority: reminder.priority
            )
            state.nextID += 1
            state.created.append(reminder)
            state.items.append(item)
            return item
        }
    }
}
