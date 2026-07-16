import Foundation

/// App-global settings, stored as `~/Simbi/.simbi/settings.json` (SPEC.md §2.1, §5.5).
///
/// Model fields are `nil` for "Default" (don't override the thread's model).
/// Decoding is resilient: missing keys fall back to defaults so old settings
/// files keep working as fields are added.
public struct SimbiSettings: Codable, Equatable, Sendable {
    public enum AudioSource: String, Codable, Sendable, CaseIterable {
        case mic
        case micAndSystem
    }

    public var fixerModel: String?
    public var converterModel: String?
    public var chatModel: String?
    public var audioSource: AudioSource

    public static let `default` = SimbiSettings()

    public init(
        fixerModel: String? = nil,
        converterModel: String? = nil,
        chatModel: String? = nil,
        audioSource: AudioSource = .micAndSystem
    ) {
        self.fixerModel = fixerModel
        self.converterModel = converterModel
        self.chatModel = chatModel
        self.audioSource = audioSource
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fixerModel = try container.decodeIfPresent(String.self, forKey: .fixerModel)
        converterModel = try container.decodeIfPresent(String.self, forKey: .converterModel)
        chatModel = try container.decodeIfPresent(String.self, forKey: .chatModel)
        audioSource = try container.decodeIfPresent(AudioSource.self, forKey: .audioSource) ?? .micAndSystem
    }

    public static func load(from url: URL) throws -> SimbiSettings {
        try JSONDecoder().decode(SimbiSettings.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
