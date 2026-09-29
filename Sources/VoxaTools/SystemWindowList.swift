import AppKit
import CoreGraphics
import Foundation

/// The windows on the screen, as the window server has them. Bounds and owners need no permission.
public struct SystemWindowList: WindowHitTesting {
    public init() {}

    /// The window a mouse click at `point` (top-left origin, in points) would land on.
    ///
    /// This asks the window server's own hit test, not the list of windows: the list has the Dock's transparent full-screen
    /// window above everything (found by testing this against a real window), and reading "who is on top" from it would call every
    /// click covered. The hit test passes over such overlays, as a click does, and finds windows the person can see.
    public func topWindow(at point: CGPoint) -> WindowHit? {
        let number = Self.windowNumber(at: point)
        guard number > 0 else { return nil }
        return window(withID: UInt32(number))
    }

    public func window(withID id: UInt32) -> WindowHit? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(id)) as? [[String: Any]] else { return nil }
        return list.lazy.compactMap(Self.hit).first { $0.windowID == id }
    }

    /// AppKit's hit test wants the main thread and coordinates measured up from the bottom left of the main display.
    private static func windowNumber(at point: CGPoint) -> Int {
        let ask: @Sendable () -> Int = {
            MainActor.assumeIsolated {
                let height = NSScreen.screens.first?.frame.height ?? 0
                return NSWindow.windowNumber(at: NSPoint(x: point.x, y: height - point.y), belowWindowWithWindowNumber: 0)
            }
        }
        return Thread.isMainThread ? ask() : DispatchQueue.main.sync(execute: ask)
    }

    /// A window that could be clicked: on screen, visible, and with an area. Menu-bar clutter and fully transparent overlays
    /// don't count; a floating panel, a pop-up menu or Voxa's own card does, because a click would land on it.
    static func hit(from info: [String: Any]) -> WindowHit? {
        guard let pid = info[kCGWindowOwnerPID as String] as? Int32, let number = info[kCGWindowNumber as String] as? UInt32,
            let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
            let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary)
        else { return nil }
        let alpha = (info[kCGWindowAlpha as String] as? Double) ?? 1
        let layer = (info[kCGWindowLayer as String] as? Int) ?? 0
        guard alpha > 0.01, bounds.width > 0, bounds.height > 0, layer >= 0 else { return nil }
        return WindowHit(pid: pid, windowID: number, frame: bounds)
    }
}
