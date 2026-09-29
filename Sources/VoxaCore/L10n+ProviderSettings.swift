// swiftlint:disable line_length
// Localized strings carry translator comments, so their lines are long by nature.
import Foundation

/// The Model tab of Settings, for whichever provider is chosen.
extension L10n {
    public enum SettingsProvider {
        public static var provider: String {
            String(localized: "Provider", comment: "Settings label for the picker that chooses Claude, OpenAI or Ollama")
        }

        public static func summary(for provider: ModelProvider) -> String {
            switch provider {
            case .anthropic:
                String(localized: "Claude, from Anthropic. Needs an Anthropic API key.", comment: "Settings summary under the provider picker")
            case .openAI:
                String(localized: "GPT models, from OpenAI. Needs an OpenAI API key.", comment: "Settings summary under the provider picker")
            case .ollama:
                String(localized: "Models that run on this Mac through Ollama. No key needed.", comment: "Settings summary under the provider picker")
            }
        }

        // MARK: API keys

        public static func keyTitle(for provider: ModelProvider) -> String {
            switch provider {
            case .anthropic: String(localized: "Anthropic API key", comment: "Settings section title")
            case .openAI: String(localized: "OpenAI API key", comment: "Settings section title")
            case .ollama: String(localized: "Ollama", comment: "Settings section title")
            }
        }

        public static func keyPlaceholder(for provider: ModelProvider) -> String {
            switch provider {
            case .anthropic: String(localized: "Paste your key (sk-ant-…)", comment: "Placeholder in the Anthropic API key field")
            case .openAI: String(localized: "Paste your key (sk-…)", comment: "Placeholder in the OpenAI API key field")
            case .ollama: ""
            }
        }

        public static func privacy(for provider: ModelProvider) -> String {
            switch provider {
            case .anthropic:
                SettingsModel.privacy
            case .openAI:
                String(
                    localized: "Your voice is turned into text on this Mac and never leaves it. The text of your command, and anything a tool reads for you, is sent to OpenAI to decide what to do; Voxa asks OpenAI not to store the conversation. The key is kept in the macOS Keychain.",
                    comment: "Settings privacy note under the OpenAI API key"
                )
            case .ollama:
                String(
                    localized: "Your voice is turned into text on this Mac and never leaves it. With a model that runs on this Mac, neither does the text of your command. Models marked as cloud models run on Ollama's servers instead.",
                    comment: "Settings privacy note for Ollama"
                )
            }
        }

        // MARK: Model

        public static func modelHelp(for provider: ModelProvider) -> String {
            switch provider {
            case .anthropic, .ollama: SettingsModel.modelHelp
            case .openAI:
                String(localized: "The default is quick and inexpensive. Any OpenAI model that can use tools works.", comment: "Help under the OpenAI model field")
            }
        }

        public static func effortHelp(for provider: ModelProvider) -> String {
            switch provider {
            case .anthropic, .openAI: SettingsModel.effortHelp
            case .ollama:
                String(localized: "Quick turns thinking off for models that allow it. Other models think as they normally do.", comment: "Help under the thinking picker for Ollama")
            }
        }

        // MARK: OpenAI server

        public static var serverAddress: String {
            String(localized: "Server address", comment: "Settings label for the API server address")
        }
        public static var openAIAddressHelp: String {
            String(localized: "Only change this to use another server that speaks OpenAI's API. Your key is only ever sent over https, or to this Mac.", comment: "Help under the OpenAI server address")
        }

        // MARK: Ollama

        public static var ollamaServer: String {
            String(localized: "Server", comment: "Settings label for the Ollama server address")
        }
        public static var ollamaAddressHelp: String {
            String(localized: "Ollama runs on this Mac by default, and then your commands stay on it. Use another address to reach one on your network. Models marked cloud run on Ollama's servers.", comment: "Help under the Ollama server address")
        }
        public static var ollamaChecking: String {
            String(localized: "Checking…", comment: "Ollama status while asking the server")
        }
        public static func ollamaRunning(version: String) -> String {
            String(localized: "Running (version \(version))", comment: "Ollama status; the argument is a version number")
        }
        public static var ollamaNotRunning: String {
            String(localized: "Not running. Open Ollama, then refresh.", comment: "Ollama status when nothing answers")
        }
        public static var ollamaBadAddress: String {
            String(localized: "That isn't a valid address.", comment: "Ollama status when the address can't be used")
        }
        public static var refresh: String {
            String(localized: "Refresh", comment: "Button that asks the Ollama server again")
        }
        public static var noModelsInstalled: String {
            String(localized: "No models installed yet. In Terminal, run “ollama pull qwen3” (any model that can use tools works).", comment: "Ollama hint when the server has no models")
        }
        public static var chooseModel: String {
            String(localized: "Choose a model…", comment: "Placeholder in the Ollama model picker")
        }
        public static var modelPlaceholder: String {
            String(localized: "Model name, for example qwen3:8b", comment: "Placeholder in the Ollama model field")
        }
        public static func notInstalled(_ model: String) -> String {
            String(localized: "\(model) (not installed)", comment: "Ollama model picker entry for a chosen model the server doesn't have")
        }
        public static func cloudSuffix(_ name: String) -> String {
            String(localized: "\(name) — cloud", comment: "Ollama model picker entry for a model that runs on Ollama's servers")
        }
        public static var contextLength: String {
            String(localized: "Context window", comment: "Settings label for the Ollama context window size")
        }
        public static func contextValue(_ tokens: Int) -> String {
            String(localized: "\(tokens.formatted()) tokens", comment: "Ollama context window value")
        }
        public static var contextHelp: String {
            String(localized: "How much text the model reads at once. Voxa's instructions and tools need about 8,000; more uses more memory.", comment: "Help under the context window")
        }
        public static func cannotUseTools(_ model: String) -> String {
            String(localized: "\(model) can't use tools, so Voxa can't act with it. Choose one that can, such as qwen3 or llama3.1.", comment: "Warning under the Ollama model picker")
        }
        public static var cloudModelWarning: String {
            String(localized: "This model runs on Ollama's servers, so your commands leave this Mac.", comment: "Warning under the Ollama model picker for cloud models")
        }
        public static var browseModels: String {
            String(localized: "Find models", comment: "Button that opens Ollama's model library")
        }
    }
}
// swiftlint:enable line_length
