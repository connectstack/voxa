import Foundation
import VoxaCore

/// The tools Voxa ships with, wired to the real system. Each later milestone adds to this list.
public enum StandardTools {
    public static func make(
        catalog: any AppCataloging = SystemAppCatalog(),
        opener: any AppOpening = WorkspaceOpener(),
        runner: any ProcessRunning = SystemProcessRunner(),
        system: SystemAccess = .real()
    ) -> [any AgentTool] {
        [
            OpenAppTool(catalog: catalog, opener: opener),
            OpenURLTool(catalog: catalog, opener: opener),
            ListShortcutsTool(runner: runner),
            RunShortcutTool(runner: runner),
            RunAppleScriptTool(runner: runner),
            CalendarListEventsTool(calendars: system.calendar),
            CalendarCreateEventTool(calendars: system.calendar),
            CalendarUpdateEventTool(calendars: system.calendar),
            CalendarDeleteEventTool(calendars: system.calendar),
            ReminderListTool(reminders: system.reminders),
            ReminderCreateTool(reminders: system.reminders),
            ClipboardReadTool(clipboard: system.clipboard),
            ClipboardWriteTool(clipboard: system.clipboard),
            FrontmostContextTool(provider: system.frontmost),
        ]
    }
}
