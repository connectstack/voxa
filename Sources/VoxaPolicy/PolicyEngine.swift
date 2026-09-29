import Foundation
import VoxaCore

/// The settings the policy reads. Changing them affects only calls that haven't been decided yet.
public struct PolicyConfiguration: Sendable, Equatable {
    public var strictness: ConfirmationStrictness
    public var disabledTools: Set<String>

    public init(strictness: ConfirmationStrictness = .standard, disabledTools: Set<String> = []) {
        self.strictness = strictness
        self.disabledTools = disabledTools
    }
}

/// What outside content has entered the conversation. Once the model has read something an attacker could have written (a
/// web page, the clipboard, a file, a script's output), everything it does afterwards is potentially steered by it, so the
/// policy asks before acting. The taint lasts as long as that content stays in the model's context: a whole conversation,
/// not a single command, because a "wait for the next command" instruction is the obvious way to slip past a per-command check.
public struct RunTaint: Sendable, Equatable {
    /// Where the outside content came from, in order, without repeats ("clipboard", "AppleScript output").
    public private(set) var sources: [String] = []

    public init() {}

    public var isTainted: Bool { !sources.isEmpty }

    /// Records a tool result. An untrusted result taints only if it actually put something in front of the model.
    public mutating func absorb(_ result: ToolResult) {
        guard case .untrusted(let source) = result.provenance, result.hasContent else { return }
        if !sources.contains(source) { sources.append(source) }
    }
}

public enum PolicyDecision: Sendable, Equatable {
    /// Run without saying anything.
    case allow
    /// Run, and show the user what is happening.
    case allowWithNotice(String)
    /// Ask first. The prompt is built from the tool's own description of the call.
    case requireConfirmation(ConfirmationPrompt)
    /// Never run. The reason is shown to the user and returned to the model.
    case deny(reason: String)
}

/// Per-tool minimum risk that lives in the policy, independent of what a tool declares about itself. If a tool's own
/// classification is ever wrong (a refactor, a copy-paste), the tools that can do the most damage still ask.
public enum PolicyFloors {
    public static func floor(for toolName: String) -> RiskLevel {
        switch toolName {
        case "run_applescript", "run_shortcut", "file_move", "file_trash", "calendar_update_event", "calendar_delete_event": .sensitive
        case "ui_click", "ui_type", "ui_press_keys", "screenshot", "clipboard_read", "clipboard_write", "calendar_create_event",
            "reminders_create":
            .reversible
        default: .readOnly
        }
    }
}

/// Decides what happens to a validated tool call. Pure and deterministic: the same call in the same state always gets the
/// same answer, which is what makes the security rules testable exhaustively.
///
/// The rules, in order:
/// 1. A tool the user turned off never runs. A call the tool itself refuses (`block`) never runs.
/// 2. **Risk only goes up.** The effective risk is the highest of the tool's declared baseline, the tool's assessment of
///    this particular call, and the policy's own floor for that tool. Nothing the model says can lower it: the model
///    supplies arguments, never a risk level, a "confirmed" flag or a description.
/// 3. `sensitive` always asks.
/// 4. `reversible` asks if outside content has been read (taint) or the user chose strict confirmation.
/// 5. `readOnly` asks only under paranoid confirmation.
/// 6. The confirmation shows what the *tool's code* says the call will do, never model-written text.
public struct PolicyEngine: Sendable {
    public var configuration: PolicyConfiguration

    public init(configuration: PolicyConfiguration = PolicyConfiguration()) {
        self.configuration = configuration
    }

    /// The risk a call is judged at: the highest of what the tool declares, what it says about this call, and the policy's floor.
    public static func effectiveRisk(toolName: String, baselineRisk: RiskLevel, assessment: ToolAssessment) -> RiskLevel {
        max(baselineRisk, assessment.risk, PolicyFloors.floor(for: toolName))
    }

    public func evaluate(
        toolName: String,
        baselineRisk: RiskLevel,
        assessment: ToolAssessment,
        taint: RunTaint
    ) -> PolicyDecision {
        if configuration.disabledTools.contains(toolName) {
            return .deny(reason: L10n.Policy.toolDisabled(toolName))
        }
        if let block = assessment.block {
            return .deny(reason: block)
        }

        let risk = Self.effectiveRisk(toolName: toolName, baselineRisk: baselineRisk, assessment: assessment)
        var reasons = assessment.reasons
        var mustConfirm = false

        switch risk {
        case .sensitive:
            mustConfirm = true
            if reasons.isEmpty { reasons.append(L10n.Policy.sensitiveAsks) }
        case .reversible:
            if taint.isTainted {
                mustConfirm = true
                reasons.append(L10n.Policy.taint(taint.sources))
            } else if configuration.strictness.rank >= ConfirmationStrictness.strict.rank {
                mustConfirm = true
                reasons.append(L10n.Policy.strictAsks)
            }
        case .readOnly:
            if configuration.strictness == .paranoid {
                mustConfirm = true
                reasons.append(L10n.Policy.paranoidAsks)
            }
        }
        // Outside content in play makes even a "sensitive" prompt worth explaining.
        if risk == .sensitive, taint.isTainted {
            reasons.append(L10n.Policy.taint(taint.sources))
        }

        guard mustConfirm else {
            return risk == .readOnly ? .allow : .allowWithNotice(assessment.title)
        }
        return .requireConfirmation(
            ConfirmationPrompt(
                toolName: toolName,
                title: TextSanitizer.forDisplay(assessment.title),
                summary: TextSanitizer.forDisplay(assessment.summary),
                details: assessment.details.map {
                    DetailRow(TextSanitizer.forDisplay($0.label), TextSanitizer.forDisplay($0.value), style: $0.style)
                },
                targetApp: assessment.targetApp.map(TextSanitizer.forDisplay),
                risk: risk,
                reasons: reasons.map(TextSanitizer.forDisplay)
            )
        )
    }
}
