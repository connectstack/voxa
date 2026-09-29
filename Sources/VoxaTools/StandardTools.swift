import Foundation
import VoxaCore

/// The tools Voxa ships with, wired to the real system (or to sample data, for a Debug run or a test).
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
            UIInspectTool(ui: system.ui),
            UIClickTool(ui: system.ui),
            UITypeTool(ui: system.ui),
            UIPressKeysTool(ui: system.ui),
            ScreenshotTool(capturer: system.screen, apps: system.ui, registry: system.screenshots),
            FileSearchTool(files: system.files),
            RevealInFinderTool(files: system.files),
            FileMoveTool(files: system.files),
            FileTrashTool(files: system.files),
        ]
    }
}
