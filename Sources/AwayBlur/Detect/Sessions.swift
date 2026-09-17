import Foundation

/// What the agents next door are up to, read from cmux's own state on disk.
///
/// No API and no process to talk to: cmux writes its window state and its
/// notification history as it goes, and both are readable. Nothing here is
/// load bearing — if the files move or change shape, the line simply goes
/// away.
enum Sessions {

    private static var support: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/cmux", isDirectory: true)
    }

    private static func json(_ name: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: support.appendingPathComponent(name)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    /// Panel id to the title shown on its tab, with cmux's status glyph and
    /// any emoji taken off the front.
    private static func titles() -> [String: String] {
        guard let root = json("session-com.cmuxterm.app.json"),
              let windows = root["windows"] as? [[String: Any]] else { return [:] }
        var found: [String: String] = [:]
        for window in windows {
            guard let manager = window["tabManager"] as? [String: Any],
                  let workspaces = manager["workspaces"] as? [[String: Any]] else { continue }
            for workspace in workspaces {
                for panel in workspace["panels"] as? [[String: Any]] ?? [] {
                    guard let id = panel["id"] as? String, let title = panel["title"] as? String else { continue }
                    found[id] = clean(title)
                }
            }
        }
        return found
    }

    private static func clean(_ title: String) -> String {
        let trimmed = title.drop { character in
            character.isWhitespace || !(character.isLetter || character.isNumber)
        }
        return String(trimmed).trimmingCharacters(in: .whitespaces)
    }

    /// The session that most recently asked for something and has not been
    /// read, if it asked recently enough to still be true.
    static func waiting(within window: TimeInterval = 45 * 60) -> String? {
        guard let root = json("notification-feed-history-com.cmuxterm.app.json"),
              let feed = root["notifications"] as? [[String: Any]] else { return nil }
        let now = Date().timeIntervalSinceReferenceDate
        let unread = feed.filter { entry in
            (entry["isRead"] as? Bool) == false
                && now - ((entry["createdAt"] as? Double) ?? 0) < window
        }
        guard let newest = unread.max(by: { (($0["createdAt"] as? Double) ?? 0) < (($1["createdAt"] as? Double) ?? 0) })
        else { return nil }
        let names = titles()
        let name = (newest["panelId"] as? String).flatMap { names[$0] }
        let count = unread.count
        if let name, !name.isEmpty {
            let short = name.count > 22 ? String(name.prefix(21)) + "…" : name
            return count > 1 ? "\(short.uppercased()) +\(count - 1) WAITING" : "\(short.uppercased()) IS WAITING"
        }
        return count == 1 ? "A SESSION IS WAITING" : "\(count) SESSIONS WAITING"
    }

    /// How many panels cmux is showing a working glyph on.
    static func open() -> Int { titles().count }
}
