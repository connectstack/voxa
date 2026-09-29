import Foundation
import Testing
import VoxaCore
import VoxaLLM
@testable import VoxaSettings
import VoxaTestSupport

@MainActor
@Suite("API key form")
struct APIKeyFormModelTests {
    private func form(
        key: String? = nil,
        test: @escaping @Sendable () async -> UserFacingError? = { nil }
    ) -> (APIKeyFormModel, InMemoryAPIKeyStore) {
        let store = InMemoryAPIKeyStore(key: key)
        return (APIKeyFormModel(keys: store, testConnection: test), store)
    }

    @Test("with no key the entry field is shown, and Save needs something typed")
    func startsEmpty() {
        let (form, _) = form()
        #expect(!form.hasKey)
        #expect(form.showsEntryField)
        #expect(!form.canSave)
        form.input = "   \n"
        #expect(!form.canSave, "whitespace alone isn't a key")
        form.input = "sk-ant-abc"
        #expect(form.canSave)
    }

    @Test("saving stores the trimmed key, clears the field, and shows that a key exists (not the key)")
    func save() async throws {
        let (form, store) = form()
        form.input = "  sk-ant-abc123 \n"
        form.save()
        #expect(form.input.isEmpty, "the typed key must not linger in the form")
        #expect(form.hasKey)
        #expect(!form.showsEntryField)
        #expect(form.error == nil)
        #expect(try await store.apiKey() == "sk-ant-abc123")
    }

    @Test("a key that can't be right is refused with a plain message, and what was typed is kept for fixing")
    func invalidKey() {
        let (form, store) = form()
        form.input = "sk-ant abc"
        form.save()
        #expect(form.error == UserFacingError.describing(APIKeyError.containsWhitespace).detail)
        #expect(form.input == "sk-ant abc")
        #expect(!form.hasKey && !store.hasKey())
    }

    @Test("removing deletes the key and brings the entry field back")
    func remove() {
        let (form, store) = form(key: "sk-ant-abc")
        #expect(form.hasKey && !form.showsEntryField)
        form.remove()
        #expect(!form.hasKey && !store.hasKey())
        #expect(form.showsEntryField)
    }

    @Test("replacing shows the field over the saved key; cancelling clears what was typed and keeps the old key")
    func replace() async throws {
        let (form, store) = form(key: "sk-ant-old")
        form.beginReplacing()
        #expect(form.showsEntryField)
        form.input = "sk-ant-new"
        form.cancelReplacing()
        #expect(form.input.isEmpty && !form.isReplacing && !form.showsEntryField)
        #expect(try await store.apiKey() == "sk-ant-old")

        form.beginReplacing()
        form.input = "sk-ant-new"
        form.save()
        #expect(try await store.apiKey() == "sk-ant-new")
        #expect(!form.isReplacing)
    }

    @Test("testing reports progress and then success or the failure's title")
    func connection() async {
        let ok = form(key: "sk-ant-abc") { nil }.0
        #expect(ok.connection == .idle)
        await ok.test()
        #expect(ok.connection == .connected)

        let failing = form(key: "sk-ant-abc") { UserFacingError(title: "Your API key was rejected", detail: "Check the key.") }.0
        await failing.test()
        #expect(failing.connection == .failed("Your API key was rejected"))
    }

    @Test("the test shows as in progress while the request is out")
    func testing() async {
        let gate = AsyncGate()
        let (form, _) = form(key: "sk-ant-abc") {
            await gate.wait()
            return nil
        }
        let task = Task { await form.test() }
        #expect(await waitUntil { form.connection == .testing })
        await gate.open()
        await task.value
        #expect(form.connection == .connected)
    }

    @Test("changing the key resets an earlier test result")
    func resultResets() async {
        let (form, _) = form(key: "sk-ant-abc")
        await form.test()
        #expect(form.connection == .connected)
        form.beginReplacing()
        form.input = "sk-ant-other"
        form.save()
        #expect(form.connection == .idle)
    }

    @Test("refresh notices a key added or removed elsewhere")
    func refresh() throws {
        let (form, store) = form()
        try store.save("sk-ant-elsewhere")
        #expect(!form.hasKey)
        form.refresh()
        #expect(form.hasKey)
    }
}
