import Foundation
import VoxaCore

/// Opens (or brings to the front) an application by name.
public struct OpenAppTool: TypedTool {
    public struct Input: ToolInput {
        public let name: String
    }

    public let name = "open_app"
    public let summary = """
        Opens an application by its name, or brings it to the front if it is already running. Use this for "open Safari" or \
        "switch to Notes". It only launches the app; to open a web page use open_url, and to act inside an app use a more \
        specific tool.
        """
    public let inputSchema = Schema.object(
        [
            "name": Schema.string(
                "The application's name as a person would say it, for example \"Safari\" or \"Visual Studio Code\".",
                minLength: 1,
                maxLength: 100
            )
        ],
        required: ["name"]
    )
    public let baselineRisk = RiskLevel.reversible
    public let requiredPermissions: Set<PermissionKind> = []
    public let stepKind = TaskStepKind.opens

    private let catalog: any AppCataloging
    private let opener: any AppOpening

    public init(catalog: any AppCataloging, opener: any AppOpening) {
        self.catalog = catalog
        self.opener = opener
    }

    private func resolve(_ query: String) throws -> InstalledApp {
        switch AppMatcher.resolve(query, in: catalog.apps()) {
        case .found(let app):
            return app
        case .ambiguous(let candidates):
            let names = candidates.map(\.name).joined(separator: ", ")
            throw ToolInputError("'\(query)' could mean several apps: \(names). Ask the user which one they want.")
        case .notFound(let suggestions):
            let hint =
                suggestions.isEmpty
                ? "The name may have been misheard; ask the user to repeat it."
                : "Did the user mean: \(suggestions.joined(separator: ", "))? Ask before opening one."
            throw ToolInputError("No installed app matches '\(query)'. \(hint)")
        }
    }

    public func assess(_ input: Input) throws -> ToolAssessment {
        let app = try resolve(input.name)
        return ToolAssessment(
            risk: .reversible,
            title: "Open \(app.name)",
            summary: "Opens \(app.name), or brings it to the front if it is already running.",
            details: [DetailRow("App", app.name), DetailRow("Location", app.url.path)],
            targetApp: app.name
        )
    }

    public func run(_ input: Input, context: ToolContext) async throws -> ToolResult {
        let app = try resolve(input.name)
        try await opener.open(app)
        return .text("Opened \(app.name).", notice: "Opened \(app.name)")
    }
}
