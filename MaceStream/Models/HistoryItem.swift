import Foundation

struct HistoryItem: Codable, Identifiable, Hashable, Sendable {
    var contentID: String
    var customTitle: String?
    var isFavorite: Bool
    var addedAt: Date
    var lastPlayedAt: Date
    var playCount: Int

    var id: String { contentID }

    var link: AceStreamLink {
        AceStreamLink(contentID: contentID)
    }

    var displayTitle: String {
        if let customTitle,
           !customTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return customTitle
        }
        return "AceStream \(link.shortID)"
    }

    init(
        contentID: String,
        customTitle: String? = nil,
        isFavorite: Bool = false,
        addedAt: Date = Date(),
        lastPlayedAt: Date = Date(),
        playCount: Int = 1
    ) {
        self.contentID = contentID
        self.customTitle = customTitle
        self.isFavorite = isFavorite
        self.addedAt = addedAt
        self.lastPlayedAt = lastPlayedAt
        self.playCount = playCount
    }
}
