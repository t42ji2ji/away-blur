import Foundation

/// What the agents next door are up to: Claude Code and Codex, read from the
/// state each of them keeps on disk.
///
/// No API and no process to talk to. Claude Code keeps one small file per
/// running session with its status in it; Codex writes every turn to a log,
/// and the last start or finish in it says which way the turn went. Nothing
/// here is load bearing — if the files move or change shape, the dots and the
/// line simply go away.
enum Sessions {

    enum State { case working, waiting }

    struct Session {
        let id: String
        /// The folder it is working in, which is what you would call it.
        let name: String
        let state: State
    }

    /// A finished session is news for this long, and after that it is just a
    /// window somebody left open.
    static let fresh: TimeInterval = 45 * 60

    /// Every session that is working, or that finished recently enough to be
    /// waiting on you. Working first, then by name, so the dots keep their
    /// order from one look to the next.
    static func all() -> [Session] {
        (claude() + codex()).sorted { a, b in
            a.state != b.state ? a.state == .working : a.name < b.name
        }
    }

    /// The line under the cat, when something is waiting on you.
    static func line(for sessions: [Session]) -> String? {
        let waiting = sessions.filter { $0.state == .waiting }
        guard let first = waiting.first else { return nil }
        let short = first.name.count > 22 ? String(first.name.prefix(21)) + "…" : first.name
        return waiting.count > 1 ? "\(short.uppercased()) +\(waiting.count - 1) WAITING"
                                 : "\(short.uppercased()) IS WAITING"
    }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    private static func folder(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    // MARK: - Claude Code

    /// `~/.claude/sessions/<pid>.json`, one per running session, with a status
    /// of `busy` or `idle`. Anything else is a state this does not know, and
    /// it is left out rather than guessed at.
    private static func claude() -> [Session] {
        let directory = home.appendingPathComponent(".claude/sessions", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        let now = Date().timeIntervalSince1970
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = object["pid"] as? Int32, kill(pid, 0) == 0,
                  let status = object["status"] as? String,
                  let cwd = object["cwd"] as? String else { return nil }
            let id = object["sessionId"] as? String ?? "\(pid)"
            switch status {
            case "busy":
                return Session(id: id, name: folder(cwd), state: .working)
            case "idle":
                let since = (object["statusUpdatedAt"] as? Double ?? 0) / 1000
                guard now - since < fresh else { return nil }
                return Session(id: id, name: folder(cwd), state: .waiting)
            default:
                return nil
            }
        }
    }

    // MARK: - Codex

    /// `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`, one per conversation.
    /// Only today's and yesterday's folders, and only files touched recently:
    /// a turn in progress writes all the time, so a log that has gone quiet
    /// for longer than `fresh` is not working on anything.
    private static func codex() -> [Session] {
        let root = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        let now = Date()
        let days = [now, now.addingTimeInterval(-86_400)].map { formatter.string(from: $0) }
        var found: [Session] = []
        for day in Set(days) {
            let directory = root.appendingPathComponent(day, isDirectory: true)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names where name.hasSuffix(".jsonl") {
                let file = directory.appendingPathComponent(name)
                guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate,
                      now.timeIntervalSince(modified) < fresh,
                      let session = codexSession(file) else { continue }
                found.append(session)
            }
        }
        return found
    }

    private static func codexSession(_ file: URL) -> Session? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        // The folder is in the first line; the first line also carries the
        // whole of the instructions, so it is read in a slice, not parsed.
        guard let head = try? handle.read(upToCount: 64 * 1024),
              let cwd = match(#""cwd":"([^"]+)""#, in: String(decoding: head, as: UTF8.self)) else { return nil }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 256 * 1024 ? size - 256 * 1024 : 0)
        guard let tail = try? handle.readToEnd() else { return nil }
        let text = String(decoding: tail, as: UTF8.self)
        let started = text.range(of: #""type":"task_started""#, options: .backwards)?.lowerBound
        let ended = [#""type":"task_complete""#, #""type":"turn_aborted""#]
            .compactMap { text.range(of: $0, options: .backwards)?.lowerBound }
            .max()
        let state: State
        switch (started, ended) {
        case let (start?, end?): state = start > end ? .working : .waiting
        case (_?, nil): state = .working
        case (nil, _?): state = .waiting
        case (nil, nil): return nil
        }
        return Session(id: file.lastPathComponent, name: folder(cwd), state: state)
    }

    private static func match(_ pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let found = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(found.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
