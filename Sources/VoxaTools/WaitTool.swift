import Foundation
import VoxaCore

/// Pauses for a few seconds, so a page or an app that was just opened can finish appearing before the next step looks at it.
///
/// Opening something and reading it are separate steps, and the second can't start until the first has drawn something. Without
/// this the model either looks too soon (a blank window) or gives up and reports the opening as the whole job.
public struct WaitTool: TypedTool {
    public struct Input: ToolInput {
        public let seconds: Int?
    }

    public static let defaultSeconds = 3
    public static let maxSeconds = 10

    public let name = "wait"
    public let summary = """
        Waits a few seconds so a page or an app can finish opening. Use it after open_url or open_app, and after a click that \
        loads a new page, whenever your next step is to look at that window or click something in it. About 3 seconds suits a \
        web page. Do not use it to pass the time.
        """
    public let inputSchema = Schema.object([
        "seconds": Schema.integer(
            "How long to wait, from 1 to \(WaitTool.maxSeconds). Default \(WaitTool.defaultSeconds).",
            minimum: 1,
            maximum: WaitTool.maxSeconds
        )
    ])
    public let baselineRisk = RiskLevel.readOnly
    public let requiredPermissions: Set<PermissionKind> = []

    private let sleep: @Sendable (Duration) async throws -> Void

    /// - Parameter sleep: How to wait. Tests pass one that returns at once.
    public init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    private func seconds(_ input: Input) -> Int {
        min(max(input.seconds ?? Self.defaultSeconds, 1), Self.maxSeconds)
    }

    public func assess(_ input: Input) throws -> ToolAssessment {
        let seconds = seconds(input)
        return ToolAssessment(
            risk: .readOnly,
            title: "Wait \(seconds) second\(seconds == 1 ? "" : "s")",
            summary: "Waits \(seconds) second\(seconds == 1 ? "" : "s") for the page or app to finish opening."
        )
    }

    public func run(_ input: Input, context: ToolContext) async throws -> ToolResult {
        let seconds = seconds(input)
        try await sleep(.seconds(seconds))
        return .text("Waited \(seconds) second\(seconds == 1 ? "" : "s").")
    }
}
