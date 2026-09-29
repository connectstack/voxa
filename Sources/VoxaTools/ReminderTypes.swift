import Foundation

public enum ReminderPriority: String, Sendable, Equatable, CaseIterable {
    case none, low, medium, high
}

public struct ReminderListInfo: Sendable, Equatable {
    public var name: String
    public var allowsModifications: Bool

    public init(name: String, allowsModifications: Bool = true) {
        self.name = name
        self.allowsModifications = allowsModifications
    }
}

/// A reminder as tools see it.
public struct ReminderItem: Sendable, Equatable {
    public var id: String
    public var title: String
    public var due: Date?
    /// The reminder is due on a day, with no time of day.
    public var dueIsDayOnly: Bool
    public var notes: String?
    public var list: String
    public var priority: ReminderPriority
    public var isCompleted: Bool

    public init(
        id: String,
        title: String,
        due: Date? = nil,
        dueIsDayOnly: Bool = false,
        notes: String? = nil,
        list: String = "Reminders",
        priority: ReminderPriority = .none,
        isCompleted: Bool = false
    ) {
        self.id = id
        self.title = title
        self.due = due
        self.dueIsDayOnly = dueIsDayOnly
        self.notes = notes
        self.list = list
        self.priority = priority
        self.isCompleted = isCompleted
    }
}

public struct NewReminder: Sendable, Equatable {
    public var title: String
    public var due: Date?
    public var dueIsDayOnly: Bool
    public var notes: String?
    /// The list's name, or nil for the user's default list.
    public var list: String?
    public var priority: ReminderPriority

    public init(
        title: String,
        due: Date? = nil,
        dueIsDayOnly: Bool = false,
        notes: String? = nil,
        list: String? = nil,
        priority: ReminderPriority = .none
    ) {
        self.title = title
        self.due = due
        self.dueIsDayOnly = dueIsDayOnly
        self.notes = notes
        self.list = list
        self.priority = priority
    }
}

public enum ReminderError: Error, Sendable, Equatable, LocalizedError {
    case listNotFound(String, available: [String])
    case listIsReadOnly(String)
    case noDefaultList
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .listNotFound(let name, let available):
            "There is no reminders list named '\(name)'. The lists are: \(available.joined(separator: ", "))."
        case .listIsReadOnly(let name):
            "The list '\(name)' is read-only, so nothing can be added to it."
        case .noDefaultList:
            "There is no default reminders list. Name one."
        case .failed(let reason):
            reason
        }
    }
}

/// The user's reminders, behind a protocol so the tools are tested without EventKit.
public protocol RemindersAccessing: Sendable {
    func lists() -> [ReminderListInfo]
    /// Reminders in `list` (all lists if nil), soonest due first, undated last.
    func reminders(in list: String?, includeCompleted: Bool, limit: Int) async throws -> [ReminderItem]
    func create(_ reminder: NewReminder) throws -> ReminderItem
}
