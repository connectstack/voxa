import VoxaCore

/// The tools the agent may use, by name.
public struct ToolRegistry: Sendable {
    private let tools: [String: any AgentTool]

    /// Tool names are the model's only handle on a tool, so a duplicate is a programming error, not a runtime condition.
    public init(_ tools: [any AgentTool]) {
        var map: [String: any AgentTool] = [:]
        for tool in tools {
            precondition(map[tool.name] == nil, "Two tools are named '\(tool.name)'")
            map[tool.name] = tool
        }
        self.tools = map
    }

    public var names: [String] { tools.keys.sorted() }

    public func tool(named name: String) -> (any AgentTool)? {
        tools[name]
    }

    /// What the model is told about, minus anything the user turned off. Sorted, so the request bytes don't depend on
    /// registration order.
    public func definitions(excluding disabled: Set<String> = []) -> [ToolDefinition] {
        tools.values
            .filter { !disabled.contains($0.name) }
            .map(\.definition)
            .sorted { $0.name < $1.name }
    }
}
