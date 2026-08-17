import Foundation

/// The four Codex worker roles that take per-feature model/effort
/// overrides (SPEC.md §5.5). One source for the row order and labels the
/// Settings pane and the onboarding wizard render.
public enum AgentRole: String, CaseIterable, Identifiable, Sendable {
    case fixer, converter, summary, title

    public var id: String { rawValue }

    /// Row label; matches `AgentInstructions.title` vocabulary.
    public var title: String {
        switch self {
        case .fixer: "Transcript fixer"
        case .converter: "File converter"
        case .summary: "AI notes"
        case .title: "Note title"
        }
    }
}

/// One role's override pair. `nil` means "Default" (don't override the
/// thread's model, or the model's own effort).
public struct ModelChoice: Equatable, Sendable {
    public var model: String?
    public var effort: String?

    public init(model: String? = nil, effort: String? = nil) {
        self.model = model
        self.effort = effort
    }
}

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
    /// Reasoning-effort overrides; `nil` for the model's own default.
    public var fixerEffort: String?
    public var converterEffort: String?
    public var summaryEffort: String?
    public var titleEffort: String?
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
        fixerEffort: String? = nil,
        converterEffort: String? = nil,
        summaryEffort: String? = nil,
        titleEffort: String? = nil,
        micEnabled: Bool = true,
        micDeviceUID: String? = nil,
        systemAudioEnabled: Bool = true
    ) {
        self.fixerModel = fixerModel
        self.converterModel = converterModel
        self.summaryModel = summaryModel
        self.titleModel = titleModel
        self.fixerEffort = fixerEffort
        self.converterEffort = converterEffort
        self.summaryEffort = summaryEffort
        self.titleEffort = titleEffort
        self.micEnabled = micEnabled
        self.micDeviceUID = micDeviceUID
        self.systemAudioEnabled = systemAudioEnabled
    }

    private enum CodingKeys: String, CodingKey {
        // chatModel existed before the terminal chat; old files may still
        // carry it and it is simply ignored on decode.
        case fixerModel, converterModel, summaryModel, titleModel
        case fixerEffort, converterEffort, summaryEffort, titleEffort
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
        fixerEffort = try container.decodeIfPresent(String.self, forKey: .fixerEffort)
        converterEffort = try container.decodeIfPresent(String.self, forKey: .converterEffort)
        summaryEffort = try container.decodeIfPresent(String.self, forKey: .summaryEffort)
        titleEffort = try container.decodeIfPresent(String.self, forKey: .titleEffort)
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
        try container.encodeIfPresent(fixerEffort, forKey: .fixerEffort)
        try container.encodeIfPresent(converterEffort, forKey: .converterEffort)
        try container.encodeIfPresent(summaryEffort, forKey: .summaryEffort)
        try container.encodeIfPresent(titleEffort, forKey: .titleEffort)
        try container.encode(micEnabled, forKey: .micEnabled)
        try container.encodeIfPresent(micDeviceUID, forKey: .micDeviceUID)
        try container.encode(systemAudioEnabled, forKey: .systemAudioEnabled)
    }

    public static func load(from url: URL) throws -> SimbiSettings {
        try JSONDecoder().decode(SimbiSettings.self, from: Data(contentsOf: url))
    }

    /// The settings as stored right now; a missing or corrupt file reads
    /// as the defaults.
    public static func current(home: SimbiHome = SimbiHome()) -> SimbiSettings {
        (try? load(from: home.settingsFileURL)) ?? .default
    }

    /// Role-keyed access to the per-feature override pairs; the flat
    /// stored fields above stay the settings.json wire format.
    public subscript(role: AgentRole) -> ModelChoice {
        get {
            switch role {
            case .fixer: ModelChoice(model: fixerModel, effort: fixerEffort)
            case .converter: ModelChoice(model: converterModel, effort: converterEffort)
            case .summary: ModelChoice(model: summaryModel, effort: summaryEffort)
            case .title: ModelChoice(model: titleModel, effort: titleEffort)
            }
        }
        set {
            switch role {
            case .fixer:
                fixerModel = newValue.model
                fixerEffort = newValue.effort
            case .converter:
                converterModel = newValue.model
                converterEffort = newValue.effort
            case .summary:
                summaryModel = newValue.model
                summaryEffort = newValue.effort
            case .title:
                titleModel = newValue.model
                titleEffort = newValue.effort
            }
        }
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
