import SQLite3
import XCTest
@testable import Codenotch

/// OpenCode's unfinished turns, credited to the metered account each one is
/// spending — and to nobody when the account is not one Codenotch meters.
final class OpenCodeActivityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_000_000)
    private var databases: [URL] = []

    override func tearDownWithError() throws {
        for url in databases {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        databases = []
    }

    /// One session per turn, each with a single message, written and closed
    /// before the reader opens it.
    private func makeDatabase(_ turns: [(session: String, provider: String, completed: Bool, at: Date)],
                              directory: String = "/Users/x/Projects/codenotch") throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opencode-billing-\(UUID().uuidString).db")
        databases.append(url)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(db, """
        CREATE TABLE session (id TEXT, parent_id TEXT, title TEXT, directory TEXT, time_updated INTEGER);
        CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
        """, nil, nil, nil)
        for (index, turn) in turns.enumerated() {
            let millis = Int(turn.at.timeIntervalSince1970 * 1000)
            let completed = turn.completed ? #","completed":\#(millis + 10)"# : ""
            let data = #"{"role":"assistant","providerID":"\#(turn.provider)","modelID":"m","time":{"created":\#(millis)\#(completed)}}"#
            sqlite3_exec(db, """
            INSERT INTO session VALUES ('\(turn.session)', NULL, 'title', '\(directory)', \(millis));
            INSERT INTO message VALUES ('m\(index)', '\(turn.session)', \(millis), \(millis), '\(data)');
            """, nil, nil, nil)
        }
        sqlite3_close(db)
        return url
    }

    /// Each plan-specific id reaches the provider that meters that plan.
    func testTurnsAreCreditedToTheAccountTheySpend() throws {
        let url = try makeDatabase([
            ("s1", "opencode-go", false, now),
            ("s2", "zai-coding-plan", false, now),
            ("s3", "zhipuai-coding-plan", false, now),
            ("s4", "github-copilot", false, now),
            ("s5", "minimax-coding-plan", false, now),
            ("s6", "kimi-code-plan-global", false, now),
            ("s7", "ollama-cloud", false, now),
            ("s8", "deepseek", false, now),
        ])
        let sessions = OpenCodeActivity.sessions(database: url, staleAfter: 45, now: now)
        XCTAssertEqual(sessions["opencode"]?.map(\.id), ["opencode.opencode.s1"])
        XCTAssertEqual(Set(sessions["glm"]?.map(\.id) ?? []), ["glm.opencode.s2", "glm.opencode.s3"])
        XCTAssertEqual(sessions["copilot"]?.count, 1)
        XCTAssertEqual(sessions["minimax"]?.count, 1)
        XCTAssertEqual(sessions["kimi"]?.count, 1)
        XCTAssertEqual(sessions["ollama"]?.count, 1)
        XCTAssertEqual(sessions["deepseek"]?.count, 1)
        XCTAssertEqual(sessions["opencode"]?.first?.state, .busy)
        XCTAssertEqual(sessions["opencode"]?.first?.detail, "Working in codenotch")
    }

    /// Pay-as-you-go APIs of the same vendors spend nothing those rings
    /// measure, `anthropic`/`openai` cannot be tied to one profile, and
    /// `google` belongs to the Gemini API monitor, which reads it itself.
    func testTurnsNoCodenotchPlanPaysForAreNobodys() throws {
        let url = try makeDatabase([
            ("s1", "zai", false, now), ("s2", "minimax", false, now), ("s3", "anthropic", false, now),
            ("s4", "openai", false, now), ("s5", "google", false, now), ("s6", "lmstudio", false, now),
        ])
        let sessions = OpenCodeActivity.sessions(database: url, staleAfter: 45, now: now)
        XCTAssertTrue(sessions.values.allSatisfy(\.isEmpty), "\(sessions)")
        XCTAssertEqual(Set(sessions.keys), Set(OpenCodeActivity.billing.values),
                       "every provider still has an answer: watched, and idle")
        XCTAssertEqual(OpenCodeGeminiActivity.read(database: url, staleAfter: 45, now: now).map(\.id),
                       ["gemini-api.opencode.s5"], "the Gemini ring's own reader still sees its turn")
    }

    func testFinishedAndStaleTurnsAreNotWork() throws {
        let url = try makeDatabase([
            ("s1", "opencode-go", true, now),
            ("s2", "zai-coding-plan", false, now.addingTimeInterval(-600)),
        ])
        let sessions = OpenCodeActivity.sessions(database: url, staleAfter: 45, now: now)
        XCTAssertEqual(sessions["opencode"], [])
        XCTAssertEqual(sessions["glm"], [])
    }

    // MARK: - The source

    @MainActor
    func testTheSourceSaysNothingWithoutADatabaseAndIdleOrWorkingWithOne() throws {
        let missing = OpenCodeActivitySource(database: URL(fileURLWithPath: "/nonexistent/opencode.db"))
        missing.poll(now: now)
        XCTAssertNil(missing.sessions, "OpenCode is not installed: unknown, not idle")

        let url = try makeDatabase([("s1", "github-copilot", false, now)])
        let source = OpenCodeActivitySource(database: url)
        var states: [String: ProviderActivityState] = [:]
        let subscription = source.statesPublisher.sink { states = $0 }
        defer { subscription.cancel() }
        source.poll(now: now)
        XCTAssertEqual(states["copilot"], .active)
        XCTAssertEqual(states["opencode"], .idle)
        XCTAssertEqual(source.providerIDs, Set(OpenCodeActivity.billing.values))

        // Past the staleness window the turn is over, and since one was in
        // flight the source looks again even with the files untouched.
        source.poll(now: now.addingTimeInterval(120))
        XCTAssertEqual(states["copilot"], .idle)
    }
}
