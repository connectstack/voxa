import Foundation
import VoxaCore
import VoxaPolicy

/// Working out what a move or a trash would touch, before anything is described to the user or done: which items, that they
/// exist, that the rules allow changing them, and where each one would end up. The same planning runs again when the action
/// is carried out, because the disk can change between being asked and acting.
enum FileChangePlanning {
    static let maxItems = 25
    static let listedInCard = 8

    struct Item {
        var url: URL
        var status: FileStatus
    }

    /// The items named, or the arguments' problem (`ToolInputError`) or a reason the rules forbid changing one (`refusal`).
    static func sources(_ raw: [String], files: any FileAccessing) throws -> (items: [Item], refusal: String?) {
        guard !raw.isEmpty else { throw ToolInputError("There are no paths. Name at least one file or folder.") }
        guard raw.count <= maxItems else { throw ToolInputError("Name at most \(maxItems) items at a time.") }
        var items: [Item] = []
        var seen: Set<String> = []
        var refusal: String?
        for path in raw {
            let url = try resolve(path, files: files)
            guard seen.insert(url.path).inserted else { throw ToolInputError("\(files.policy.display(url)) is listed twice.") }
            let status = files.status(of: url)
            guard status.exists else {
                throw ToolInputError("Nothing exists at \(files.policy.display(url)). Check the path, or search for it first.")
            }
            if refusal == nil, let problem = files.policy.modificationProblem(for: url) {
                refusal = "Voxa won't change \(files.policy.display(url)). \(problem)"
            }
            items.append(Item(url: url, status: status))
        }
        return (items, refusal)
    }

    static func resolve(_ path: String, files: any FileAccessing) throws -> URL {
        do {
            return try files.policy.resolve(path)
        } catch let error as FilePathPolicy.PathError {
            throw ToolInputError(error.explanation)
        }
    }

    /// One row per item, up to a handful, then a row that says how many more there are.
    static func rows(_ items: [Item], label: String, files: any FileAccessing) -> [DetailRow] {
        var rows = items.prefix(listedInCard).map { item -> DetailRow in
            var description = files.policy.display(item.url)
            let facts = [
                item.status.kind, item.status.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) },
            ]
            .compactMap { $0 }.filter { !$0.isEmpty }
            if !facts.isEmpty { description += "  (\(facts.joined(separator: ", ")))" }
            return DetailRow(label, description)
        }
        if items.count > listedInCard { rows.append(DetailRow("And", "\(items.count - listedInCard) more")) }
        return rows
    }

    static func noun(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count) items"
    }
}

// MARK: - file_trash

/// Moves files to the Trash. Never deletes anything outright.
public struct FileTrashTool: TypedTool {
    public struct Input: ToolInput {
        public let paths: [String]
    }

    public let name = "file_trash"
    public let summary = """
        Moves files or folders to the Trash, which the user can empty or restore from. This is the only way Voxa gets rid of a \
        file: it never deletes one outright. Find the paths with file_search first; don't guess them. The user is always asked \
        first, and is shown the list.
        """
    public let inputSchema = Schema.object(
        [
            "paths": Schema.array(
                of: Schema.string("A full path, or one starting with ~.", minLength: 1, maxLength: 500),
                "The items to move to the Trash.",
                minItems: 1,
                maxItems: FileChangePlanning.maxItems
            )
        ],
        required: ["paths"]
    )
    public let baselineRisk = RiskLevel.sensitive
    public let requiredPermissions: Set<PermissionKind> = []

    private let files: any FileAccessing

    public init(files: any FileAccessing) {
        self.files = files
    }

    public func assess(_ input: Input) throws -> ToolAssessment {
        let plan = try FileChangePlanning.sources(input.paths, files: files)
        let title = "Move \(FileChangePlanning.noun(plan.items.count)) to the Trash"
        if let refusal = plan.refusal {
            return ToolAssessment(risk: .sensitive, title: title, summary: "Voxa won't do this.", block: refusal)
        }
        return ToolAssessment(
            risk: .sensitive,
            title: title,
            summary: "Moves \(FileChangePlanning.noun(plan.items.count)) to the Trash.",
            details: FileChangePlanning.rows(plan.items, label: "Item", files: files),
            reasons: ["They stay in the Trash until it is emptied, and Put Back returns them to where they were."]
        )
    }

    public func run(_ input: Input, context: ToolContext) async throws -> ToolResult {
        let plan = try FileChangePlanning.sources(input.paths, files: files)
        if let refusal = plan.refusal { return .error(refusal) }

        var done = 0
        var firstFailure: FileError?
        for item in plan.items {
            do {
                _ = try files.trash(item.url)
                done += 1
            } catch let error as FileError {
                firstFailure = firstFailure ?? error
            }
        }
        if let failure = firstFailure {
            return .error("Moved \(done) of \(plan.items.count) to the Trash. The rest could not be moved: \(failure.message).")
        }
        return .text(
            "Moved \(FileChangePlanning.noun(done)) to the Trash. They can be restored from there.",
            notice: "Moved \(FileChangePlanning.noun(done)) to the Trash"
        )
    }
}

// MARK: - file_move

/// Moves files into a folder, or renames one. Never replaces anything.
public struct FileMoveTool: TypedTool {
    public struct Input: ToolInput {
        public let paths: [String]
        public let destination: String
        // swiftlint:disable:next discouraged_optional_boolean
        public let createFolder: Bool?

        enum CodingKeys: String, CodingKey {
            case paths, destination
            case createFolder = "create_folder"
        }
    }

    public let name = "file_move"
    public let summary = """
        Moves files or folders into a folder, or gives one item a new name or place. It never replaces anything: if something \
        with that name is already there, it stops. Find the paths with file_search first; don't guess them. The user is always \
        asked first, and is shown where things are going.
        """
    public let inputSchema = Schema.object(
        [
            "paths": Schema.array(
                of: Schema.string("A full path, or one starting with ~.", minLength: 1, maxLength: 500),
                "The items to move.",
                minItems: 1,
                maxItems: FileChangePlanning.maxItems
            ),
            "destination": Schema.string(
                "An existing folder to move the items into. For a single item, it may instead be the new full path (a new name).",
                minLength: 1,
                maxLength: 500
            ),
            "create_folder": Schema.boolean("Make the destination folder first, when it doesn't exist. Its parent must exist."),
        ],
        required: ["paths", "destination"]
    )
    public let baselineRisk = RiskLevel.sensitive
    public let requiredPermissions: Set<PermissionKind> = []

    private let files: any FileAccessing

    public init(files: any FileAccessing) {
        self.files = files
    }

    /// Where the items go, and how that came about.
    struct Plan {
        enum Kind {
            case intoFolder
            case rename
            case intoNewFolder
        }

        var kind: Kind
        var moves: [(from: URL, to: URL)]
        /// The folder to make first, for `.intoNewFolder`.
        var folderToCreate: URL?
        /// What the person named as the destination.
        var destination: URL
        var refusal: String?

        /// The folder the items end up in, for the card and the reply.
        var folder: URL { folderToCreate ?? (kind == .rename ? moves[0].to.deletingLastPathComponent() : destination) }
    }

    private func plan(_ input: Input) throws -> (items: [FileChangePlanning.Item], plan: Plan) {
        let sources = try FileChangePlanning.sources(input.paths, files: files)
        let policy = files.policy
        let destination = try FileChangePlanning.resolve(input.destination, files: files)
        let (kind, targets, folderToCreate) = try targets(
            for: sources.items, destination: destination, create: input.createFolder ?? false)

        var refusal = sources.refusal
        var moves: [(from: URL, to: URL)] = []
        for (item, target) in zip(sources.items, targets) {
            try check(item.url, target)
            if refusal == nil, let problem = policy.modificationProblem(for: target) {
                refusal = "Voxa won't move things to \(policy.display(target)). \(problem)"
            }
            moves.append((item.url, target))
        }
        let plan = Plan(kind: kind, moves: moves, folderToCreate: folderToCreate, destination: destination, refusal: refusal)
        return (sources.items, plan)
    }

    /// Where each item would land. The destination is followed through any link first, so a folder that is really a way out of
    /// the home folder is judged by where it leads.
    private func targets(
        for items: [FileChangePlanning.Item],
        destination: URL,
        create: Bool
    ) throws -> (Plan.Kind, [URL], URL?) {
        let policy = files.policy
        let status = files.status(of: destination)
        if status.exists {
            guard status.isDirectory else {
                throw ToolInputError(
                    "There is already a file at \(policy.display(destination)). Name a folder, or a name that isn't taken.")
            }
            let folder = destination.resolvingSymlinksInPath()
            return (.intoFolder, items.map { folder.appendingPathComponent($0.url.lastPathComponent) }, nil)
        }
        let parent = destination.deletingLastPathComponent()
        if items.count == 1, !create {
            // A new name for the one item; the folder it lands in has to exist.
            try requireFolder(parent)
            return (.rename, [parent.resolvingSymlinksInPath().appendingPathComponent(destination.lastPathComponent)], nil)
        }
        guard create else {
            throw ToolInputError(
                "\(policy.display(destination)) doesn't exist. To move several items there, set create_folder; or name a folder that exists."
            )
        }
        try requireFolder(parent)
        let made = parent.resolvingSymlinksInPath().appendingPathComponent(destination.lastPathComponent)
        return (.intoNewFolder, items.map { made.appendingPathComponent($0.url.lastPathComponent) }, made)
    }

    private func requireFolder(_ url: URL) throws {
        let status = files.status(of: url)
        guard status.exists, status.isDirectory else {
            throw ToolInputError("The folder \(files.policy.display(url)) doesn't exist, so nothing can be put in it.")
        }
    }

    private func check(_ source: URL, _ target: URL) throws {
        if source.path == target.path {
            throw ToolInputError("\(files.policy.display(source)) is already there.")
        }
        if target.path.hasPrefix(source.path + "/") {
            throw ToolInputError("A folder can't be moved into itself.")
        }
        if files.status(of: target).exists {
            let folder = files.policy.display(target.deletingLastPathComponent())
            throw ToolInputError("Something named \(target.lastPathComponent) is already at \(folder). Nothing is replaced.")
        }
    }

    public func assess(_ input: Input) throws -> ToolAssessment {
        let (items, plan) = try plan(input)
        let place = files.policy.display(plan.folder)
        let title = plan.kind == .rename ? "Move and rename 1 item" : "Move \(FileChangePlanning.noun(items.count)) to \(place)"
        if let refusal = plan.refusal {
            return ToolAssessment(risk: .sensitive, title: title, summary: "Voxa won't do this.", block: refusal)
        }
        var details = FileChangePlanning.rows(items, label: "Move", files: files)
        details.append(DetailRow("To", plan.kind == .rename ? files.policy.display(plan.moves[0].to) : place))
        var reasons = ["Nothing is replaced: if something with the same name is already there, it stops."]
        if plan.folderToCreate != nil { reasons.append("Makes the folder \(place) first.") }
        return ToolAssessment(
            risk: .sensitive,
            title: title,
            summary: plan.kind == .rename
                ? "Moves 1 item to \(files.policy.display(plan.moves[0].to))."
                : "Moves \(FileChangePlanning.noun(items.count)) to \(place).",
            details: details,
            reasons: reasons
        )
    }

    public func run(_ input: Input, context: ToolContext) async throws -> ToolResult {
        let (_, plan) = try plan(input)
        if let refusal = plan.refusal { return .error(refusal) }
        do {
            if let folder = plan.folderToCreate { try files.createFolder(at: folder) }
        } catch let error as FileError {
            return .error("The folder could not be made: \(error.message).")
        }

        var done = 0
        var firstFailure: FileError?
        for move in plan.moves {
            do {
                try files.move(from: move.from, to: move.to)
                done += 1
            } catch let error as FileError {
                firstFailure = firstFailure ?? error
            }
        }
        if let failure = firstFailure {
            return .error("Moved \(done) of \(plan.moves.count) items. The rest could not be moved: \(failure.message).")
        }
        let place = files.policy.display(plan.kind == .rename ? plan.moves[0].to : plan.folder)
        return .text("Moved \(FileChangePlanning.noun(done)) to \(place).", notice: "Moved \(FileChangePlanning.noun(done))")
    }
}
