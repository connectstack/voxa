import Foundation

/// A Whisper speech model Voxa can use. These are the sizes worth offering for push-to-talk commands: bigger ones are more
/// accurate but slower than the pause a person will wait through.
public struct WhisperModel: Identifiable, Sendable, Equatable {
    /// The variant name the model host uses: `base.en`.
    public let id: String
    public let name: String
    /// Whether it understands English only (and is then a little better at it).
    public let isEnglishOnly: Bool
    /// About how much is downloaded, in megabytes. Shown before anything is fetched.
    public let approximateMegabytes: Int
    /// Where this model is stored, under the models folder: the folder its files are downloaded into.
    public var folderName: String { "openai_whisper-\(id)" }

    public init(id: String, name: String, isEnglishOnly: Bool, approximateMegabytes: Int) {
        self.id = id
        self.name = name
        self.isEnglishOnly = isEnglishOnly
        self.approximateMegabytes = approximateMegabytes
    }
}

public enum WhisperModelCatalog {
    /// Small enough to download quickly and to answer within about a second on an Apple-silicon Mac.
    public static let all: [WhisperModel] = [
        WhisperModel(id: "tiny", name: "Tiny", isEnglishOnly: false, approximateMegabytes: 80),
        WhisperModel(id: "base.en", name: "Base", isEnglishOnly: true, approximateMegabytes: 150),
        WhisperModel(id: "base", name: "Base", isEnglishOnly: false, approximateMegabytes: 150),
        WhisperModel(id: "small.en", name: "Small", isEnglishOnly: true, approximateMegabytes: 490),
        WhisperModel(id: "small", name: "Small", isEnglishOnly: false, approximateMegabytes: 490),
    ]

    public static let defaultID = "base.en"

    public static func model(_ id: String) -> WhisperModel? {
        all.first { $0.id == id }
    }

    /// The model to suggest for a recognition language: the English one for English, the multilingual one otherwise.
    public static func recommendedID(for locale: Locale) -> String {
        locale.language.languageCode?.identifier == "en" ? "base.en" : "base"
    }
}
