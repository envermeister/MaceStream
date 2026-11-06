import Foundation

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var items: [HistoryItem] = []
    @Published private(set) var persistenceError: String?

    private let paths: SupportPaths
    private let maximumItems: Int

    init(paths: SupportPaths = .production, maximumItems: Int = 60) {
        self.paths = paths
        self.maximumItems = maximumItems
        load()
    }

    func record(_ link: AceStreamLink) {
        let now = Date()
        if let index = items.firstIndex(where: { $0.contentID == link.contentID }) {
            items[index].lastPlayedAt = now
            items[index].playCount += 1
        } else {
            items.append(HistoryItem(contentID: link.contentID, addedAt: now, lastPlayedAt: now))
        }
        trimAndSave()
    }

    func toggleFavorite(_ item: HistoryItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isFavorite.toggle()
        trimAndSave()
    }

    func rename(_ item: HistoryItem, to title: String?) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        items[index].customTitle = trimmed?.isEmpty == true ? nil : trimmed
        trimAndSave()
    }

    func remove(_ item: HistoryItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        items = []
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: paths.historyURL) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            items = try decoder.decode([HistoryItem].self, from: data)
            sortAndTrim()
        } catch {
            persistenceError = "Could not read history: \(error.localizedDescription)"
        }
    }

    private func trimAndSave() {
        sortAndTrim()
        save()
    }

    private func sortAndTrim() {
        items.sort {
            if $0.isFavorite != $1.isFavorite { return $0.isFavorite && !$1.isFavorite }
            return $0.lastPlayedAt > $1.lastPlayedAt
        }
        if items.count > maximumItems {
            items = Array(items.prefix(maximumItems))
        }
    }

    private func save() {
        do {
            try paths.createDirectories()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(items).write(to: paths.historyURL, options: .atomic)
            persistenceError = nil
        } catch {
            persistenceError = "Could not save history: \(error.localizedDescription)"
        }
    }
}
