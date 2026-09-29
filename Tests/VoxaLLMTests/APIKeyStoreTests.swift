import Foundation
import Testing
import VoxaCore
@testable import VoxaLLM

@Suite("API key storage")
struct APIKeyStoreTests {
    @Test("a saved key is returned, and surrounding whitespace from a paste is trimmed")
    func saveAndRead() async throws {
        let store = InMemoryAPIKeyStore()
        #expect(!store.hasKey())
        try store.save("  sk-ant-abc123\n")
        #expect(store.hasKey())
        #expect(try await store.apiKey() == "sk-ant-abc123")
    }

    @Test("with no key stored, reading fails with the error that tells the user what to do")
    func missing() async {
        await #expect(throws: LLMError.missingAPIKey) { try await InMemoryAPIKeyStore().apiKey() }
    }

    @Test(
        "blank keys and keys containing spaces are rejected",
        arguments: [
            ("", APIKeyError.empty), ("   \n", APIKeyError.empty), ("sk ant", APIKeyError.containsWhitespace),
            ("a\tb", APIKeyError.containsWhitespace),
        ]
    )
    func rejected(text: String, expected: APIKeyError) {
        #expect(throws: expected) { try InMemoryAPIKeyStore().save(text) }
    }

    @Test("deleting removes the key")
    func delete() async throws {
        let store = InMemoryAPIKeyStore(key: "k")
        try store.delete()
        #expect(!store.hasKey())
    }

    @Test("errors have plain wording and the right recovery")
    func wording() {
        #expect(LLMError.missingAPIKey.userFacing.recovery == .openModelSettings)
        #expect(LLMError.authentication("x").userFacing.recovery == .openModelSettings)
        #expect(LLMError.modelNotFound("x").userFacing.recovery == .openModelSettings)
        #expect(LLMError.rateLimited(retryAfter: nil).userFacing.recovery == nil)
        for error in [
            LLMError.offline, .timedOut, .overloaded, .incompleteStream, .requestTooLarge,
            .server(status: 502, message: ""),
        ] {
            #expect(!error.userFacing.title.isEmpty && !error.userFacing.detail.isEmpty)
        }
    }

    /// A real Keychain round trip under a throwaway service name. It is skipped (not failed) where the Keychain isn't
    /// available to the test process, such as a locked keychain or a headless CI account.
    @Test("the Keychain store round-trips a key and removes it")
    func keychain() async throws {
        let store = KeychainAPIKeyStore(
            service: "com.rohitsainier.voxa.tests.\(UUID().uuidString)",
            account: "test-key"
        )
        do {
            try store.save("sk-ant-keychain-test")
        } catch APIKeyError.keychain(let status) {
            Issue.record("Keychain unavailable to the test process (status \(status)); skipping the round trip")
            return
        }
        defer { try? store.delete() }

        #expect(store.hasKey())
        #expect(try await store.apiKey() == "sk-ant-keychain-test")
        try store.save("sk-ant-replaced")
        #expect(try await store.apiKey() == "sk-ant-replaced")
        try store.delete()
        #expect(!store.hasKey())
        await #expect(throws: LLMError.missingAPIKey) { try await store.apiKey() }
    }

    @Test("each provider's key is its own Keychain item: saving or removing one leaves the other alone")
    func keysAreIndependent() async throws {
        let service = "com.rohitsainier.voxa.tests.\(UUID().uuidString)"
        let claude = KeychainAPIKeyStore(service: service, account: ModelProvider.anthropic.keychainAccount ?? "")
        let openAI = KeychainAPIKeyStore(service: service, account: ModelProvider.openAI.keychainAccount ?? "")
        do {
            try claude.save("sk-ant-one")
        } catch APIKeyError.keychain(let status) {
            Issue.record("Keychain unavailable to the test process (status \(status)); skipping the round trip")
            return
        }
        defer {
            try? claude.delete()
            try? openAI.delete()
        }

        #expect(claude.hasKey() && !openAI.hasKey(), "a Claude key is not an OpenAI key")
        try openAI.save("sk-openai-two")
        #expect(try await claude.apiKey() == "sk-ant-one")
        #expect(try await openAI.apiKey() == "sk-openai-two")

        try claude.delete()
        #expect(!claude.hasKey() && openAI.hasKey())
        #expect(try await openAI.apiKey() == "sk-openai-two")
    }
}
