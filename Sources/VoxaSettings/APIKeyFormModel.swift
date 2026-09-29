import Foundation
import Observation
import VoxaCore
import VoxaLLM

/// The logic behind the API key section of Settings, apart from the view, so it can be tested.
///
/// The key is held in `input` only while it is being typed: saving, cancelling and removing all clear it, and the view never
/// shows a saved key, only that one exists.
@MainActor
@Observable
final class APIKeyFormModel {
    enum Connection: Equatable {
        case idle
        case testing
        case connected
        case failed(String)
    }

    /// What is typed in the field.
    var input = ""
    private(set) var hasKey: Bool
    private(set) var isReplacing = false
    /// Plain-language reason the last save or remove failed.
    private(set) var error: String?
    private(set) var connection = Connection.idle

    @ObservationIgnored private let keys: any APIKeyStoring
    @ObservationIgnored private let testRequest: @Sendable () async -> UserFacingError?

    init(keys: any APIKeyStoring, testConnection: @escaping @Sendable () async -> UserFacingError?) {
        self.keys = keys
        self.testRequest = testConnection
        self.hasKey = keys.hasKey()
    }

    /// The field is shown when there's no key yet, or the user chose to replace it.
    var showsEntryField: Bool { !hasKey || isReplacing }

    var canSave: Bool { !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Re-reads whether a key exists (it may have been changed elsewhere).
    func refresh() {
        hasKey = keys.hasKey()
    }

    func save() {
        guard canSave else { return }
        do {
            try keys.save(input)
        } catch {
            // The text stays in the field so a stray space can be corrected.
            self.error = UserFacingError.describing(error).detail
            return
        }
        input = ""
        error = nil
        isReplacing = false
        hasKey = keys.hasKey()
        connection = .idle
    }

    func remove() {
        do {
            try keys.delete()
        } catch {
            self.error = UserFacingError.describing(error).detail
            return
        }
        error = nil
        hasKey = keys.hasKey()
        connection = .idle
    }

    func beginReplacing() {
        isReplacing = true
    }

    func cancelReplacing() {
        isReplacing = false
        input = ""
        error = nil
    }

    func test() async {
        connection = .testing
        let failure = await testRequest()
        connection = failure.map { .failed($0.title) } ?? .connected
    }
}
