import AppKit
import Foundation
import Speech
import SwiftUI
import VoxaAgent
import VoxaAudio
import VoxaCore
import VoxaHUD
import VoxaLLM
import VoxaPermissions
import VoxaPolicy
import VoxaSettings
import VoxaSpeech
import VoxaTools

// Rendering the HUD and the Settings and welcome windows to images, for `voxa-dev hud-snapshots`.

// MARK: - hud-snapshots

/// One HUD state to render.
struct Snapshot {
    var name: String
    var mode: HUDMode
    var transcript = ""
    var isFinal = false
}

@MainActor func hudSnapshotList() -> [Snapshot] {

    let stretch = "Set a timer for five minutes and remind me to stretch"
    let longCommand =
        "Open Safari and search for the best restaurants near me that are open late tonight and have "
        + "vegetarian options and outdoor seating, then add the top result to my calendar"
    let plainError = UserFacingError(title: L10n.Errors.noInputDeviceTitle, detail: L10n.Errors.noInputDeviceDetail)

    return [
        Snapshot(name: "preparing", mode: .preparing), Snapshot(name: "listening-empty", mode: .listening),
        Snapshot(name: "listening-partial", mode: .listening, transcript: stretch),
        Snapshot(name: "listening-long", mode: .listening, transcript: longCommand),
        Snapshot(name: "transcribing", mode: .transcribing, transcript: stretch, isFinal: true),
        Snapshot(name: "result", mode: .result(stretch), transcript: stretch, isFinal: true),
        Snapshot(
            name: "notice",
            mode: .notice(title: L10n.HUD.didntCatch, detail: L10n.HUD.didntCatchDetail("⌥Space"))
        ),
        Snapshot(name: "error-mic", mode: .error(.permissionRequired(.microphone, status: .denied))),
        Snapshot(name: "error-plain", mode: .error(plainError)),
        Snapshot(name: "thinking", mode: .thinking(partial: nil), transcript: stretch, isFinal: true),
        Snapshot(
            name: "thinking-partial",
            mode: .thinking(partial: "Let me set that timer for you."),
            transcript: stretch,
            isFinal: true
        ),
        Snapshot(name: "acting", mode: .acting(title: "Open Safari"), transcript: stretch, isFinal: true),
        Snapshot(name: "reply", mode: .reply("Done. I opened Safari and searched for Swift concurrency.")),
        Snapshot(
            name: "reply-long",
            mode: .reply(longCommand + ". That is everything I found; the first three results are open in Safari tabs.")
        ),
        Snapshot(name: "confirm-script", mode: .confirm(SamplePrompts.script)),
        Snapshot(name: "confirm-link", mode: .confirm(SamplePrompts.link)),
        Snapshot(name: "confirm-taint", mode: .confirm(SamplePrompts.taint)),
        Snapshot(name: "confirm-long", mode: .confirm(SamplePrompts.longScript)),
    ]
}

@MainActor func hudSnapshots(_ arguments: [String]) {
    guard let directory = arguments.first, !directory.hasPrefix("--") else {
        fail("Missing output directory.\n\n\(usage)")
    }
    let scale = CGFloat(Double(option("--scale", in: arguments) ?? "2") ?? 2)
    let outputURL = URL(fileURLWithPath: directory, isDirectory: true)
    try? FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)

    let snapshots = hudSnapshotList()

    let appearances: [(name: String, appearance: NSAppearance, backdrop: NSColor)] = [
        ("light", NSAppearance(named: .aqua)!, NSColor(calibratedRed: 0.80, green: 0.83, blue: 0.90, alpha: 1)),
        ("dark", NSAppearance(named: .darkAqua)!, NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.14, alpha: 1)),
    ]

    for snapshot in snapshots {
        for (appearanceName, appearance, backdrop) in appearances {
            let model = makeModel(for: snapshot.mode, transcript: snapshot.transcript, isFinal: snapshot.isFinal)
            guard
                let bitmap = renderBitmap(
                    of: HUDView(model: model),
                    appearance: appearance,
                    backdrop: backdrop,
                    scale: scale
                )
            else { continue }
            let file = outputURL.appendingPathComponent("hud-\(snapshot.name)-\(appearanceName).png")
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: file)
                print("wrote \(file.path) (\(bitmap.pixelsWide)×\(bitmap.pixelsHigh))")
            }
        }
    }
    settingsSnapshots(into: outputURL, scale: scale)
}

enum SamplePrompts {
    static let script = ConfirmationPrompt(
        toolName: "run_applescript",
        title: "Run an AppleScript",
        summary: "Runs an AppleScript that controls Finder.",
        details: [
            DetailRow(
                "Script",
                "tell application \"Finder\"\n  set volume output volume 30\n  activate\nend tell",
                style: .code
            ),
            DetailRow("Controls", "Finder"),
        ],
        targetApp: "Finder",
        risk: .sensitive,
        reasons: [
            "AppleScript can control other apps.", "Types keystrokes or presses keys in whichever app is in front",
        ]
    )
    static let link = ConfirmationPrompt(
        toolName: "open_url",
        title: "Open 192.168.1.1",
        summary: "Opens 192.168.1.1 in your default app.",
        details: [
            DetailRow("Site", "192.168.1.1"),
            DetailRow("Address", "http://192.168.1.1/admin?action=reboot", style: .url),
        ],
        risk: .sensitive,
        reasons: [L10n.Policy.notEncrypted, L10n.Policy.localNetwork]
    )
    static let taint = ConfirmationPrompt(
        toolName: "open_app",
        title: "Open Calculator",
        summary: "Opens Calculator, or brings it to the front if it is already running.",
        details: [DetailRow("App", "Calculator"), DetailRow("Location", "/System/Applications/Calculator.app")],
        targetApp: "Calculator",
        risk: .reversible,
        reasons: [L10n.Policy.taint(["AppleScript output"])]
    )
    static let longScript = ConfirmationPrompt(
        toolName: "run_applescript",
        title: "Run an AppleScript",
        summary: "Runs an AppleScript that controls Notes.",
        details: [
            DetailRow(
                "Script",
                (1...60).map { "make new note with properties {name:\"Note \($0)\", body:\"Body of note \($0)\"}" }
                    .joined(separator: "\n"),
                style: .code
            ),
            DetailRow("Controls", "Notes"),
        ],
        targetApp: "Notes",
        risk: .sensitive,
        reasons: ["AppleScript can control other apps."]
    )
}

/// A made-up mix of permission answers, so the Permissions tab shows every state.
@MainActor final class SnapshotPermissions: PermissionsProviding {
    func status(of kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .microphone, .speechRecognition: .granted
        case .calendars: .denied
        case .reminders, .accessibility, .automation: .notDetermined
        case .screenRecording: .restricted
        }
    }

    func request(_ kind: PermissionKind) async -> PermissionStatus { status(of: kind) }
    func openSystemSettings(for kind: PermissionKind) {}
}

/// Sample services for the pictures: the real tool list and a few permissions, with nothing behind them.
@MainActor func snapshotServices() -> SettingsServices {
    var services = SettingsServices.inert
    services.permissions = PermissionsModel(
        permissions: SnapshotPermissions(),
        kinds: SettingsServices.listedPermissions
    )
    let tools = StandardTools.make(system: .sample()).map { tool in
        ToolInfo(
            name: tool.name,
            summary: tool.summary,
            risk: max(tool.baselineRisk, PolicyFloors.floor(for: tool.name)),
            permissions: tool.requiredPermissions.sorted { $0.rawValue < $1.rawValue }
        )
    }
    services.tools = tools.sorted { $0.name < $1.name }
    return services
}

@MainActor func settingsSnapshots(into outputURL: URL, scale: CGFloat) {
    let suite = "com.rohitsainier.voxa.devtools.\(UUID().uuidString)"
    let store = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
    let services = snapshotServices()

    /// What to draw: every tab, the Model tab once for each provider (it changes with the provider), and each walkthrough page.
    var pages: [(name: String, view: AnyView, size: CGSize)] = []
    for tab in SettingsView.Tab.allCases {
        if tab == .model {
            for provider in ModelProvider.allCases {
                pages.append(
                    ("settings-model-\(provider.rawValue.lowercased())", AnyView(EmptyView()), SettingsView.contentSize)
                )
            }
        } else {
            pages.append(("settings-\(tab.rawValue)", AnyView(EmptyView()), SettingsView.contentSize))
        }
    }
    for step in 0..<WelcomePreview.stepCount {
        pages.append(
            (
                "welcome-\(step + 1)", AnyView(WelcomePreview(store: store, services: services, step: step)),
                WelcomePreview.size
            )
        )
    }

    for (appearanceName, appearance) in [
        ("light", NSAppearance(named: .aqua)!), ("dark", NSAppearance(named: .darkAqua)!),
    ] {
        for page in pages {
            let view: AnyView
            if page.name.hasPrefix("settings-") {
                // The provider is part of the page, and the page part of the name.
                let parts = page.name.split(separator: "-").map(String.init)
                var tab = SettingsView.Tab(rawValue: parts[1]) ?? .general
                store.current.provider = .anthropic
                if parts[1] == "model" {
                    tab = .model
                    store.current.provider =
                        ModelProvider.allCases.first { $0.rawValue.lowercased() == parts.last } ?? .anthropic
                }
                view = AnyView(SettingsView(store: store, services: services, navigation: SettingsNavigation(tab: tab)))
            } else {
                view = page.view
            }
            guard
                let bitmap = renderBitmap(
                    of: view,
                    appearance: appearance,
                    backdrop: .windowBackgroundColor,
                    scale: scale,
                    padding: 0
                )
            else { continue }
            let file = outputURL.appendingPathComponent("\(page.name)-\(appearanceName).png")
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: file)
                print("wrote \(file.path) (\(bitmap.pixelsWide)×\(bitmap.pixelsHigh))")
            }
        }
    }
}

@MainActor func makeModel(for mode: HUDMode, transcript: String, isFinal: Bool) -> HUDModel {
    let model = HUDModel()
    model.mode = mode
    model.transcript = transcript
    model.isTranscriptFinal = isFinal
    model.hotkeyHint = "⌥Space"
    for step in 0..<HUDModel.barCount {
        let wave = abs(sin(Double(step) / 3.2)) * 0.6 + 0.05
        model.push(level: AudioLevel(rms: Float(wave), peak: 1))
    }
    return model
}

/// Renders the HUD over a flat backdrop into a bitmap. (System materials can't be captured offscreen, so the panel's
/// translucent background appears flat here; the layout, type and colors are what these images are for.)
@MainActor func renderBitmap(
    of view: some View,
    appearance: NSAppearance,
    backdrop: NSColor,
    scale: CGFloat,
    padding: CGFloat = 28
) -> NSBitmapImageRep? {
    let host = NSHostingView(rootView: view)
    let size = host.fittingSize
    let canvasFrame = NSRect(x: 0, y: 0, width: size.width + padding * 2, height: size.height + padding * 2)
    let canvas = NSView(frame: canvasFrame)
    canvas.wantsLayer = true
    // Dynamic colors (like the window background) must be resolved for the appearance being rendered, not the app's own.
    var backdropColor = backdrop.cgColor
    appearance.performAsCurrentDrawingAppearance { backdropColor = backdrop.cgColor }
    canvas.layer?.backgroundColor = backdropColor
    host.frame = NSRect(x: padding, y: padding, width: size.width, height: size.height)
    canvas.addSubview(host)

    let window = NSWindow(contentRect: canvasFrame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = appearance
    window.contentView = canvas
    canvas.layoutSubtreeIfNeeded()

    guard
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(canvasFrame.width * scale),
            pixelsHigh: Int(canvasFrame.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
    else { return nil }
    bitmap.size = canvasFrame.size
    canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
    return bitmap
}
