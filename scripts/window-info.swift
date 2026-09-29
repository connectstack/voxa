#!/usr/bin/env swift
// Lists the on-screen windows owned by a process (default: Voxa): layer, bounds, alpha and whether it is on screen.
// Uses window *metadata* only, which macOS exposes without Screen Recording permission, so it works from any shell.
//
//   swift scripts/window-info.swift [ProcessName]

import CoreGraphics
import Foundation

let owner = CommandLine.arguments.dropFirst().first ?? "Voxa"
let options: CGWindowListOption = [.optionAll]
guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    print("could not list windows")
    exit(1)
}

let matches = windows.filter { ($0[kCGWindowOwnerName as String] as? String) == owner }
if matches.isEmpty { print("no windows for \(owner)") }
for window in matches {
    let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    let layer = window[kCGWindowLayer as String] as? Int ?? -1
    let alpha = window[kCGWindowAlpha as String] as? Double ?? -1
    let onscreen = window[kCGWindowIsOnscreen as String] as? Bool ?? false
    let x = Int(bounds["X"] ?? 0), y = Int(bounds["Y"] ?? 0), w = Int(bounds["Width"] ?? 0), h = Int(bounds["Height"] ?? 0)
    print("layer=\(layer) onscreen=\(onscreen) alpha=\(alpha) frame=(\(x), \(y), \(w)×\(h))")
}

let display = CGDisplayBounds(CGMainDisplayID())
print("main display: \(Int(display.width))×\(Int(display.height))")
