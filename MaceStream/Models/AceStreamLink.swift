import Foundation

struct AceStreamLink: Equatable, Hashable, Sendable {
    let contentID: String

    init?(rawValue: String) {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }

        let candidate: String
        if value.lowercased().hasPrefix("acestream://") {
            candidate = Self.idFromAceStreamURL(value) ?? ""
        } else {
            candidate = value
        }

        let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.count == 40,
              normalized.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            return nil
        }
        contentID = normalized
    }

    init(contentID: String) {
        precondition(contentID.count == 40)
        self.contentID = contentID.lowercased()
    }

    var url: URL {
        // The initializer has already constrained the ID to 40 ASCII hexadecimal characters.
        URL(string: "acestream://\(contentID)")!
    }

    var shortID: String {
        let uppercased = contentID.uppercased()
        return "\(uppercased.prefix(8))…\(uppercased.suffix(4))"
    }

    private static func idFromAceStreamURL(_ value: String) -> String? {
        guard let components = URLComponents(string: value) else { return nil }
        if let queryID = components.queryItems?.first(where: {
            $0.name.lowercased() == "id" || $0.name.lowercased() == "content_id"
        })?.value {
            return queryID
        }

        let host = components.host ?? ""
        if !host.isEmpty {
            return host
        }

        let path = components.path.removingPercentEncoding ?? components.path
        return path.split(separator: "/").first.map(String.init)
    }
}
