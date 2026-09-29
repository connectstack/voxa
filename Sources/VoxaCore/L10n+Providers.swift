// swiftlint:disable line_length
// Localized strings carry translator comments, so their lines are long by nature.
import Foundation

/// Strings that depend on which service is answering.
extension L10n {
    public enum Provider {
        public static var anthropic: String {
            String(localized: "Claude", comment: "Name of the Anthropic model provider in Settings")
        }
        public static var openAI: String {
            String(localized: "OpenAI", comment: "Name of the OpenAI model provider in Settings")
        }
        public static var ollama: String {
            String(localized: "Ollama", comment: "Name of the Ollama (local models) provider in Settings")
        }
    }

    /// Error wording for OpenAI and Ollama. (Claude's wording is in `LLM`, written before there were other providers.)
    public enum LLMFailure {
        // MARK: OpenAI

        public static var openAIMissingKeyTitle: String {
            String(localized: "Add your OpenAI API key", comment: "Error title when no OpenAI API key is stored")
        }
        public static var openAIAuthTitle: String {
            String(localized: "OpenAI rejected your API key", comment: "Error title for HTTP 401 from OpenAI")
        }
        public static var openAIAuthDetail: String {
            String(localized: "Check the key in Settings → Model, or create a new one at platform.openai.com.", comment: "Error detail")
        }
        public static var openAIBadRequestTitle: String {
            String(localized: "OpenAI rejected the request", comment: "Error title for HTTP 400 from OpenAI")
        }
        public static var openAIRateLimitTitle: String {
            String(localized: "OpenAI is rate-limiting this key", comment: "Error title for HTTP 429 from OpenAI")
        }
        public static var openAIQuotaTitle: String {
            String(localized: "Your OpenAI account is out of credit", comment: "Error title when OpenAI reports insufficient quota")
        }
        public static var openAIQuotaDetail: String {
            String(localized: "Add credit or check your plan in your OpenAI billing settings, then try again.", comment: "Error detail")
        }
        public static var openAIBusyTitle: String {
            String(localized: "OpenAI is busy right now", comment: "Error title for OpenAI server errors")
        }
        public static var openAIOfflineTitle: String {
            String(localized: "Can't reach OpenAI", comment: "Error title for network failures reaching OpenAI")
        }
        public static var openAITimeoutTitle: String {
            String(localized: "OpenAI took too long to answer", comment: "Error title")
        }
        public static var openAICutOffTitle: String {
            String(localized: "OpenAI's reply was cut off", comment: "Error title for truncated OpenAI streams")
        }

        // MARK: Ollama

        public static var ollamaNotRunningTitle: String {
            String(localized: "Ollama isn't running", comment: "Error title when nothing answers at the Ollama address")
        }
        public static var ollamaNotRunningDetail: String {
            String(localized: "Open the Ollama app (or run “ollama serve” in Terminal), then try again.", comment: "Error detail")
        }
        public static var ollamaMissingModelTitle: String {
            String(localized: "Choose an Ollama model", comment: "Error title when no Ollama model is selected")
        }
        public static var ollamaMissingModelDetail: String {
            String(localized: "Open Settings → Model and pick one. To install one, run “ollama pull qwen3:8b” in Terminal.", comment: "Error detail")
        }
        public static var ollamaModelNotInstalledTitle: String {
            String(localized: "That Ollama model isn't installed", comment: "Error title for HTTP 404 from Ollama")
        }
        public static func ollamaModelNotInstalledDetail(_ model: String) -> String {
            String(localized: "Run “ollama pull \(model)” in Terminal, or pick an installed model in Settings → Model.", comment: "Error detail. The argument is the model name")
        }
        public static var ollamaNoToolsTitle: String {
            String(localized: "That model can't use tools", comment: "Error title when the Ollama model has no tool support")
        }
        public static func ollamaNoToolsDetail(_ model: String) -> String {
            String(localized: "\(model) can't call tools, which Voxa needs to act. Pick a model that can, such as qwen3, in Settings → Model.", comment: "Error detail. The argument is the model name")
        }
        public static var ollamaBadRequestTitle: String {
            String(localized: "Ollama rejected the request", comment: "Error title for HTTP 400 from Ollama")
        }
        public static var ollamaProblemTitle: String {
            String(localized: "Ollama ran into a problem", comment: "Error title for Ollama server errors")
        }
        public static var ollamaProblemDetail: String {
            String(localized: "The model may have run out of memory. Try a smaller model, or close other apps.", comment: "Error detail")
        }
        public static var ollamaTimeoutTitle: String {
            String(localized: "Ollama took too long to answer", comment: "Error title")
        }
        public static var ollamaTimeoutDetail: String {
            String(localized: "The model may still be loading. Try again in a moment.", comment: "Error detail")
        }
        public static var ollamaCutOffTitle: String {
            String(localized: "Ollama's reply was cut off", comment: "Error title for truncated Ollama streams")
        }
    }
}

// swiftlint:enable line_length
