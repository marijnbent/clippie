import Foundation
import Combine

enum SnippetStoreError: LocalizedError {
    case emptyTrigger
    case invalidTriggerCharacters
    case emptyContent
    case duplicateTrigger
    
    var errorDescription: String? {
        switch self {
        case .emptyTrigger:
            return "Enter a trigger."
        case .invalidTriggerCharacters:
            return "Use letters and numbers only."
        case .emptyContent:
            return "Enter text to insert."
        case .duplicateTrigger:
            return "That trigger already exists."
        }
    }
}

final class SnippetStore: ObservableObject {
    static let shared = SnippetStore()
    
    @Published private(set) var snippets: [Snippet] = []
    
    private let defaults = UserDefaults.standard
    private let snippetsKey = "savedSnippets"
    private let persistenceQueue = DispatchQueue(label: "nl.bentjes.buffer.snippets.persistence", qos: .utility)
    
    private init() {
        load()
    }
    
    func saveSnippet(id: UUID? = nil, title: String, trigger: String, content: String) throws {
        let normalizedTrigger = Snippet.normalizeTrigger(trigger)
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingSnippet = id.flatMap { snippetID in
            snippets.first(where: { $0.id == snippetID })
        }
        
        guard !normalizedTrigger.isEmpty else { throw SnippetStoreError.emptyTrigger }
        guard Snippet.isSupportedTriggerInput(trigger) else { throw SnippetStoreError.invalidTriggerCharacters }
        guard !trimmedContent.isEmpty else { throw SnippetStoreError.emptyContent }
        guard !snippets.contains(where: { $0.trigger == normalizedTrigger && $0.id != id }) else {
            throw SnippetStoreError.duplicateTrigger
        }
        
        let snippet = Snippet(
            id: id ?? UUID(),
            title: title,
            trigger: normalizedTrigger,
            content: trimmedContent,
            usageCount: existingSnippet?.usageCount ?? 0,
            lastUsedAt: existingSnippet?.lastUsedAt
        )
        
        if let existingIndex = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[existingIndex] = snippet
        } else {
            snippets.append(snippet)
        }
        
        sortSnippets()
        
        persist()
    }
    
    func deleteSnippet(id: UUID) {
        snippets.removeAll { $0.id == id }
        persist()
    }
    
    func matches(for query: String) -> [Snippet] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedQuery = Snippet.normalizeTrigger(query)
        
        return snippets
            .filter { snippet in
                guard !normalizedQuery.isEmpty else { return true }

                return snippet.trigger.contains(normalizedQuery) ||
                    snippet.content.localizedCaseInsensitiveContains(trimmedQuery)
            }
            .sorted { lhs, rhs in
                let lhsPriority = matchPriority(for: lhs, normalizedQuery: normalizedQuery, rawQuery: trimmedQuery)
                let rhsPriority = matchPriority(for: rhs, normalizedQuery: normalizedQuery, rawQuery: trimmedQuery)

                if lhsPriority != rhsPriority {
                    return lhsPriority > rhsPriority
                }

                if lhs.usageCount != rhs.usageCount {
                    return lhs.usageCount > rhs.usageCount
                }

                let lhsLastUsedAt = lhs.lastUsedAt ?? .distantPast
                let rhsLastUsedAt = rhs.lastUsedAt ?? .distantPast
                if lhsLastUsedAt != rhsLastUsedAt {
                    return lhsLastUsedAt > rhsLastUsedAt
                }

                if lhs.trigger.count != rhs.trigger.count {
                    return lhs.trigger.count < rhs.trigger.count
                }
                
                return lhs.trigger.localizedCaseInsensitiveCompare(rhs.trigger) == .orderedAscending
            }
    }

    func exactTriggerMatch(for query: String) -> Snippet? {
        let normalizedQuery = Snippet.normalizeTrigger(query)
        guard !normalizedQuery.isEmpty else { return nil }

        return snippets.first { $0.trigger == normalizedQuery }
    }

    func expansionMatches(for query: String, limit: Int? = nil) -> [Snippet] {
        let normalizedQuery = Snippet.normalizeTrigger(query)
        let rankedMatches = snippets
            .filter { snippet in
                guard !normalizedQuery.isEmpty else { return true }
                return snippet.trigger.contains(normalizedQuery)
            }
            .sorted { lhs, rhs in
                let lhsPriority = expansionMatchPriority(for: lhs, normalizedQuery: normalizedQuery)
                let rhsPriority = expansionMatchPriority(for: rhs, normalizedQuery: normalizedQuery)

                if lhsPriority != rhsPriority {
                    return lhsPriority > rhsPriority
                }

                if lhs.usageCount != rhs.usageCount {
                    return lhs.usageCount > rhs.usageCount
                }

                let lhsLastUsedAt = lhs.lastUsedAt ?? .distantPast
                let rhsLastUsedAt = rhs.lastUsedAt ?? .distantPast
                if lhsLastUsedAt != rhsLastUsedAt {
                    return lhsLastUsedAt > rhsLastUsedAt
                }

                if lhs.trigger.count != rhs.trigger.count {
                    return lhs.trigger.count < rhs.trigger.count
                }

                return lhs.trigger.localizedCaseInsensitiveCompare(rhs.trigger) == .orderedAscending
            }

        guard let limit else { return rankedMatches }
        return Array(rankedMatches.prefix(limit))
    }

    func recordUsage(for snippetID: UUID) {
        guard let index = snippets.firstIndex(where: { $0.id == snippetID }) else { return }

        snippets[index].usageCount += 1
        snippets[index].lastUsedAt = Date()
        persist()
    }
    
    private func load() {
        guard let data = defaults.data(forKey: snippetsKey) else { return }
        
        do {
            snippets = try JSONDecoder().decode([Snippet].self, from: data)
            sortSnippets()
        } catch {
            print("[clippie] Failed to load snippets: \(error)")
        }
    }
    
    private func persist() {
        let snapshot = snippets
        
        persistenceQueue.async { [defaults, snippetsKey] in
            do {
                let data = try JSONEncoder().encode(snapshot)
                defaults.set(data, forKey: snippetsKey)
            } catch {
                print("[clippie] Failed to save snippets: \(error)")
            }
        }
    }
    
    private func sortSnippets() {
        snippets.sort { lhs, rhs in
            if lhs.trigger.localizedCaseInsensitiveCompare(rhs.trigger) == .orderedSame {
                return lhs.trigger < rhs.trigger
            }
            return lhs.trigger.localizedCaseInsensitiveCompare(rhs.trigger) == .orderedAscending
        }
    }

    private func matchPriority(for snippet: Snippet, normalizedQuery: String, rawQuery: String) -> Int {
        guard !normalizedQuery.isEmpty else { return 0 }

        if snippet.trigger == normalizedQuery {
            return 4
        }

        if snippet.trigger.hasPrefix(normalizedQuery) {
            return 3
        }

        if snippet.trigger.contains(normalizedQuery) {
            return 2
        }

        if snippet.content.localizedCaseInsensitiveContains(rawQuery) {
            return 1
        }

        return -1
    }

    private func expansionMatchPriority(for snippet: Snippet, normalizedQuery: String) -> Int {
        guard !normalizedQuery.isEmpty else { return 0 }

        if snippet.trigger == normalizedQuery {
            return 3
        }

        if snippet.trigger.hasPrefix(normalizedQuery) {
            return 2
        }

        if snippet.trigger.contains(normalizedQuery) {
            return 1
        }

        return -1
    }
}
