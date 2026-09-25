import Combine
import Foundation
import SQLite3

/// OpenCode's turns in flight, and which account each one is spending.
///
/// OpenCode keeps every message in one database, and each assistant row says
/// who is answering it and whether the answer has finished:
///
/// ```
/// message(id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT)
/// {"role":"assistant","providerID":"zai-coding-plan","modelID":"glm-4.6",
///  "time":{"created":1789000000000,"completed":1789000004120},"finish":"stop", …}
/// ```
///
/// `time.completed` is written only once the turn is over — while the model is
/// still answering the key is simply absent — so an assistant row with no
/// `completed` is a request in flight, and its `providerID` names the account
/// it is spending. That is OpenCode's own request lifecycle, not a guess from
/// recency.
///
/// The query looks at one message per session, the newest, because `message`'s
/// only index is `(session_id, time_created, id)`: there is no way to ask "what
/// changed lately" across the whole table, and this runs on the main actor
/// every couple of seconds. `session.time_updated` is the cheap pre-filter, and
/// the last message of each recently touched session is then the only JSON that
/// has to be decoded.
///
/// Sub-agent sessions carry `parent_id`, and a sub-agent is the same piece of
/// work as the session that spawned it — so it is reported under its parent.
///
/// `staleAfter` still applies on top of the unfinished-message marker: a server
/// that crashed mid-turn leaves `completed` missing forever, and without the
/// recency bound that dead row would read as working for the rest of the month.
enum OpenCodeActivity {
    static var database: URL { OpenCodeGeminiUsage.database }

    /// OpenCode's provider ids — the models.dev catalogue's — whose requests
    /// spend exactly the account a Codenotch provider meters, keyed to that
    /// provider.
    ///
    /// Only plan- or account-specific ids. `zai` and `minimax` are the same
    /// vendors' pay-as-you-go APIs, which do not touch the plans those rings
    /// measure; `anthropic` and `openai` cannot be tied to one Claude or Codex
    /// profile of several; and `google` is the Gemini API ring's, whose own
    /// monitor already reads this database for it.
    static let billing: [String: String] = [
        "opencode-go": "opencode",
        "zai-coding-plan": "glm",
        "zhipuai-coding-plan": "glm",
        "minimax-coding-plan": "minimax",
        "minimax-cn-coding-plan": "minimax",
        "kimi-code-plan-global": "kimi",
        "kimi-code-plan-cn": "kimi",
        "github-copilot": "copilot",
        "deepseek": "deepseek",
        "ollama-cloud": "ollama",
    ]

    /// An assistant turn that has not finished.
    struct Turn: Equatable {
        /// OpenCode's name for who is answering it.
        let providerID: String
        /// The top-level session it belongs to.
        let rootID: String
        let title: String
        let directory: String
        let started: Date

        /// The folder it runs in, or its title when it has none.
        var place: String {
            directory.isEmpty ? title : URL(fileURLWithPath: directory).lastPathComponent
        }
    }

    /// Every unfinished turn answered by a provider `counts` accepts, newest
    /// first, once per root session and provider.
    static func turns(database: URL = OpenCodeActivity.database,
                      staleAfter: TimeInterval, now: Date = Date(),
                      counting counts: (String) -> Bool) -> [Turn] {
        guard let db = SQLiteStore.open(database) else { return [] }
        defer { sqlite3_close(db) }

        let cutoffMillis = Int((now.timeIntervalSince1970 - staleAfter) * 1000)
        let rows = SQLiteStore.rows(
            in: db,
            sql: """
            SELECT r.id, r.title, r.directory, m.time_created, m.time_updated, m.data
            FROM session s
            JOIN session r ON r.id = COALESCE(s.parent_id, s.id)
            JOIN message m ON m.id = (SELECT id FROM message WHERE session_id = s.id
                                      ORDER BY time_created DESC LIMIT 1)
            WHERE s.time_updated >= \(cutoffMillis)
            ORDER BY m.time_updated DESC
            """,
            columns: 6
        )

        var seen: Set<String> = []
        var out: [Turn] = []
        for row in rows {
            let root = row[0]
            guard !root.isEmpty else { continue }
            guard let updated = Double(row[4]), Int(updated) >= cutoffMillis else { continue }
            guard let created = Double(row[3]) else { continue }
            guard let provider = unfinishedProvider(row[5]), counts(provider) else { continue }
            guard seen.insert("\(provider)\u{1}\(root)").inserted else { continue }
            out.append(Turn(providerID: provider, rootID: root, title: row[1], directory: row[2],
                            started: Date(timeIntervalSince1970: created / 1000)))
        }
        return out
    }

    /// Unfinished turns as sessions, keyed by the Codenotch provider each one
    /// is spending. Every provider in `billing` has an entry, empty or not.
    static func sessions(database: URL = OpenCodeActivity.database,
                         billing: [String: String] = OpenCodeActivity.billing,
                         staleAfter: TimeInterval, now: Date = Date()) -> [String: [AgentSession]] {
        var sessions = Dictionary(uniqueKeysWithValues: Set(billing.values).map { ($0, [AgentSession]()) })
        for turn in turns(database: database, staleAfter: staleAfter, now: now,
                          counting: { billing[$0] != nil }) {
            guard let account = billing[turn.providerID] else { continue }
            let id = "\(account).opencode.\(turn.rootID)"
            // Two OpenCode ids can bill one account; the root is still one
            // piece of work.
            guard sessions[account]?.contains(where: { $0.id == id }) != true else { continue }
            sessions[account, default: []].append(AgentSession(
                id: id, name: "OpenCode", detail: L10n.t("Working in \(turn.place)"),
                state: .busy, waitingFor: nil, since: turn.started))
        }
        return sessions
    }

    /// The provider answering an assistant message that has not finished, or
    /// nil for anything else. A JSON `null` arrives as `NSNull` rather than as
    /// a missing key, and both shapes mean the same thing here: nobody has
    /// recorded an end yet.
    static func unfinishedProvider(_ data: String) -> String? {
        guard let bytes = data.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: bytes),
              let message = object as? [String: Any],
              message["role"] as? String == "assistant",
              let provider = message["providerID"] as? String, !provider.isEmpty else { return nil }
        guard let time = message["time"] as? [String: Any] else { return provider }
        let completed = time["completed"]
        return completed == nil || completed is NSNull ? provider : nil
    }
}

/// OpenCode's turns, credited to the metered accounts in `billing` — one
/// database read for all of them, rather than one per provider.
///
/// Read on a two-second tick like the other monitors, but only when there can
/// be something new: while nothing is in flight, a tick whose database and
/// write-ahead log have not been written since the last look costs two `stat`
/// calls and no SQL.
@MainActor
final class OpenCodeActivitySource: ProviderActivitySource {
    let providerIDs: Set<String>
    /// Nil while there is no OpenCode database at all — nothing to watch, so
    /// its providers are unknown here rather than idle.
    @Published private(set) var sessions: [String: [AgentSession]]?

    var statesPublisher: AnyPublisher<[String: ProviderActivityState], Never> {
        $sessions
            .map { sessions in (sessions ?? [:]).mapValues(ProviderActivityState.init(sessions:)) }
            .eraseToAnyPublisher()
    }

    private let database: URL
    private let billing: [String: String]
    private let interval: TimeInterval
    private let staleAfter: TimeInterval
    private var timer: Timer?
    private var lastWrites: [Date?]?

    init(database: URL = OpenCodeActivity.database,
         billing: [String: String] = OpenCodeActivity.billing,
         interval: TimeInterval = 2,
         staleAfter: TimeInterval = 45) {
        self.database = database
        self.billing = billing
        self.providerIDs = Set(billing.values)
        self.interval = interval
        self.staleAfter = staleAfter
    }

    func start() {
        stop()
        poll()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastWrites = nil
    }

    func poll(now: Date = Date()) {
        let writes = [database, URL(fileURLWithPath: database.path + "-wal")].map(Self.modified)
        guard writes[0] != nil else {
            lastWrites = writes
            if sessions != nil { sessions = nil }
            return
        }
        let inFlight = sessions?.values.contains { !$0.isEmpty } ?? false
        // In flight, every tick counts: the turn may have finished or gone
        // stale without the files telling us.
        guard inFlight || writes != lastWrites else { return }
        lastWrites = writes
        let found = OpenCodeActivity.sessions(database: database, billing: billing,
                                              staleAfter: staleAfter, now: now)
        if found != sessions { sessions = found }
    }

    private static func modified(_ url: URL) -> Date? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
            + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
    }
}
