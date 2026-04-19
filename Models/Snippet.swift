import Foundation

struct Snippet: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var trigger: String
    var content: String
    var usageCount: Int
    var lastUsedAt: Date?
    
    init(
        id: UUID = UUID(),
        title: String,
        trigger: String,
        content: String,
        usageCount: Int = 0,
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.trigger = Self.normalizeTrigger(trigger)
        self.content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        self.usageCount = max(0, usageCount)
        self.lastUsedAt = lastUsedAt
    }
    
    var displayTitle: String {
        title.isEmpty ? ":\(trigger)" : title
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case trigger
        case content
        case usageCount
        case lastUsedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        title = (try container.decodeIfPresent(String.self, forKey: .title) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        trigger = Self.normalizeTrigger(try container.decode(String.self, forKey: .trigger))
        content = (try container.decodeIfPresent(String.self, forKey: .content) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        usageCount = max(0, try container.decodeIfPresent(Int.self, forKey: .usageCount) ?? 0)
        lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(trigger, forKey: .trigger)
        try container.encode(content, forKey: .content)
        try container.encode(usageCount, forKey: .usageCount)
        try container.encodeIfPresent(lastUsedAt, forKey: .lastUsedAt)
    }

    static func isSupportedTriggerInput(_ trigger: String) -> Bool {
        let trimmed = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutPrefix = trimmed.hasPrefix(":") ? String(trimmed.dropFirst()) : trimmed
        guard !withoutPrefix.isEmpty else { return false }

        return withoutPrefix.lowercased().unicodeScalars.allSatisfy { supportedTriggerCharacterSet.contains($0) }
    }

    static func isSupportedTriggerCharacter(_ character: String) -> Bool {
        character.lowercased().unicodeScalars.count == 1 &&
        character.lowercased().unicodeScalars.allSatisfy { supportedTriggerCharacterSet.contains($0) }
    }
    
    static func normalizeTrigger(_ trigger: String) -> String {
        let trimmed = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutPrefix = trimmed.hasPrefix(":") ? String(trimmed.dropFirst()) : trimmed
        let filtered = withoutPrefix.lowercased().unicodeScalars.filter { supportedTriggerCharacterSet.contains($0) }
        return String(String.UnicodeScalarView(filtered))
    }

    private static let supportedTriggerCharacterSet = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
}
