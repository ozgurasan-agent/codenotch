import Foundation

/// Notices when OpenCode is mid-turn against the Gemini API key.
///
/// OpenCode's database is written for reasons that have nothing to do with a
/// Gemini call, so its modification date says nothing this provider may claim.
/// Each message row, however, records who answered it and whether the answer
/// finished — see `OpenCodeActivity` — and an unfinished assistant row with
/// `providerID == "google"` is a Gemini call in flight. That is the only thing
/// here that is this provider's to report.
enum OpenCodeGeminiActivity {
    static var database: URL { OpenCodeGeminiUsage.database }

    static func read(
        database: URL = OpenCodeGeminiActivity.database,
        staleAfter: TimeInterval,
        now: Date = Date()
    ) -> [AgentSession] {
        OpenCodeActivity.turns(database: database, staleAfter: staleAfter, now: now,
                               counting: { $0 == "google" })
            .map { turn in
                AgentSession(
                    id: "gemini-api.opencode.\(turn.rootID)",
                    name: "OpenCode",
                    detail: "Working in \(turn.place)",
                    state: .busy,
                    waitingFor: nil,
                    since: turn.started
                )
            }
    }
}
