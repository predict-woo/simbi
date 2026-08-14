import Foundation

/// App-global settings, stored as `~/Simbi/.simbi/settings.json` (SPEC.md §2.1, §5.5).
///
/// Model fields are `nil` for "Default" (don't override the thread's model).
/// Decoding is resilient: missing keys fall back to defaults so old settings
/// files keep working as fields are added.
public struct SimbiSettings: Codable, Equatable, Sendable {
    public var fixerModel: String?
    public var converterModel: String?
    public var summaryModel: String?
    public var titleModel: String?
    /// Default recording sources (SPEC.md §3.1). Mic and system audio are
    /// independent; at least one is kept enabled on load.
    public var micEnabled: Bool
    /// Specific input device UID; nil follows the system default.
    public var micDeviceUID: String?
    public var systemAudioEnabled: Bool

    public static let `default` = SimbiSettings()

    public init(
        fixerModel: String? = nil,
        converterModel: String? = nil,
        summaryModel: String? = nil,
        titleModel: String? = nil,
        micEnabled: Bool = true,
        micDeviceUID: String? = nil,
        systemAudioEnabled: Bool = true
    ) {
        self.fixerModel = fixerModel
        self.converterModel = converterModel
        self.summaryModel = summaryModel
        self.titleModel = titleModel
        self.micEnabled = micEnabled
        self.micDeviceUID = micDeviceUID
        self.systemAudioEnabled = systemAudioEnabled
    }

    private enum CodingKeys: String, CodingKey {
        // chatModel existed before the terminal chat; old files may still
        // carry it and it is simply ignored on decode.
        case fixerModel, converterModel, summaryModel, titleModel
        case micEnabled, micDeviceUID, systemAudioEnabled
        /// Pre-mic-picker files stored `"mic"` / `"micAndSystem"` here.
        case audioSource
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fixerModel = try container.decodeIfPresent(String.self, forKey: .fixerModel)
        converterModel = try container.decodeIfPresent(String.self, forKey: .converterModel)
        summaryModel = try container.decodeIfPresent(String.self, forKey: .summaryModel)
        titleModel = try container.decodeIfPresent(String.self, forKey: .titleModel)
        micDeviceUID = try container.decodeIfPresent(String.self, forKey: .micDeviceUID)
        let legacySource = try container.decodeIfPresent(String.self, forKey: .audioSource)
        micEnabled = try container.decodeIfPresent(Bool.self, forKey: .micEnabled) ?? true
        systemAudioEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .systemAudioEnabled)
            ?? (legacySource != "mic")
        if !micEnabled && !systemAudioEnabled {
            micEnabled = true
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(fixerModel, forKey: .fixerModel)
        try container.encodeIfPresent(converterModel, forKey: .converterModel)
        try container.encodeIfPresent(summaryModel, forKey: .summaryModel)
        try container.encodeIfPresent(titleModel, forKey: .titleModel)
        try container.encode(micEnabled, forKey: .micEnabled)
        try container.encodeIfPresent(micDeviceUID, forKey: .micDeviceUID)
        try container.encode(systemAudioEnabled, forKey: .systemAudioEnabled)
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
