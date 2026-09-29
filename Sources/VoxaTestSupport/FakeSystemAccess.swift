import VoxaTools

// The in-memory system doubles live in VoxaTools, so Debug builds of the app can run against sample data too. Tests keep
// using the names they were written with.
public typealias FakeCalendar = InMemoryCalendar
public typealias FakeReminders = InMemoryReminders
public typealias FakeClipboard = InMemoryClipboard
public typealias FakeFrontmost = StaticFrontmostContext
