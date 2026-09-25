import Combine
import XCTest
@testable import Codenotch

/// The one shape every provider's activity is reduced to, and the board that
/// merges it — independent per provider, and silent about what is switched off.
@MainActor
final class ProviderActivityTests: XCTestCase {
    private func session(_ state: AgentSession.State, id: String = "s") -> AgentSession {
        AgentSession(id: id, name: "Session", detail: "", state: state, waitingFor: nil, since: Date())
    }

    // MARK: - Normalising sessions

    /// Only a turn in flight is work. A session waiting on you, one that just
    /// finished, and one sitting at its prompt are all running but idle.
    func testOnlyABusySessionIsActivity() {
        XCTAssertEqual(ProviderActivityState(sessions: [session(.busy)]), .active)
        XCTAssertEqual(ProviderActivityState(sessions: [session(.idle), session(.busy, id: "b")]), .active)
        for state in [AgentSession.State.waiting, .success, .idle] {
            XCTAssertEqual(ProviderActivityState(sessions: [session(state)]), .idle, "\(state)")
        }
        XCTAssertEqual(ProviderActivityState(sessions: []), .idle,
                       "a monitor that is running and sees nothing is watching, not unknowing")
    }

    func testMergingPrefersWorkThenWatching() {
        XCTAssertEqual(ProviderActivityState.merged([.unknown, .idle, .active]), .active)
        XCTAssertEqual(ProviderActivityState.merged([.unknown, .idle]), .idle)
        XCTAssertEqual(ProviderActivityState.merged([.unknown]), .unknown)
        XCTAssertEqual(ProviderActivityState.merged([]), .unknown)
    }

    // MARK: - The board

    private func board(consumed: Set<String>) -> ProviderActivityBoard {
        let board = ProviderActivityBoard()
        board.setConsumed(consumed)
        return board
    }

    /// Each provider keeps its own state: there is no single "working" flag.
    func testEveryProviderIsIndependent() {
        let board = board(consumed: ["a", "b", "c"])
        board.report(["a": .active, "b": .idle, "c": .active], from: "agents")
        XCTAssertEqual(board.state(for: "a"), .active)
        XCTAssertEqual(board.state(for: "b"), .idle)
        XCTAssertEqual(board.state(for: "c"), .active)

        board.report(["a": .idle, "b": .idle, "c": .active], from: "agents")
        XCTAssertEqual(board.state(for: "a"), .idle, "a finishing stops a alone")
        XCTAssertEqual(board.state(for: "c"), .active)
    }

    /// Two sources can speak for one provider; either seeing work is work.
    func testSourcesAreMergedPerProvider() {
        let board = board(consumed: ["kimi", "copilot"])
        board.report(["kimi": .idle], from: "agents")
        board.report(["kimi": .active, "copilot": .idle], from: "opencode")
        XCTAssertEqual(board.state(for: "kimi"), .active)
        board.report(["kimi": .idle, "copilot": .idle], from: "opencode")
        XCTAssertEqual(board.state(for: "kimi"), .idle)
    }

    /// A new report replaces the source's last one, and an empty one takes
    /// everything it said back.
    func testAReportReplacesAndAnEmptyOneWithdraws() {
        let board = board(consumed: ["a", "b"])
        board.report(["a": .active, "b": .active], from: "relay")
        board.report(["a": .active], from: "relay")
        XCTAssertEqual(board.state(for: "b"), .unknown, "b was not repeated, so nothing says it any more")
        board.report([:], from: "relay")
        XCTAssertEqual(board.states, [:])
        XCTAssertEqual(board.state(for: "a"), .unknown)
    }

    /// A provider absent from the menu-bar summary has no consumer, even if a
    /// source that already runs for another reason still has something to say.
    func testAProviderThatIsNotConsumedIsUnknown() {
        let board = board(consumed: ["a"])
        board.report(["a": .active, "hidden": .active], from: "agents")
        XCTAssertEqual(board.state(for: "hidden"), .unknown)
        XCTAssertNil(board.states["hidden"])
        board.setConsumed(["a", "hidden"])
        XCTAssertEqual(board.state(for: "hidden"), .active, "what was said applies once it is on")
        board.setConsumed([])
        XCTAssertEqual(board.states, [:])
    }

    /// Publishes only on a real change, so the menu bar is not asked to redraw
    /// for a monitor's steady state.
    func testTheBoardPublishesOnlyChanges() {
        let board = board(consumed: ["a"])
        var published: [[String: ProviderActivityState]] = []
        let subscription = board.$states.dropFirst().sink { published.append($0) }
        defer { subscription.cancel() }
        board.report(["a": .idle], from: "agents")
        board.report(["a": .idle], from: "agents")
        board.report(["a": .idle], from: "relay")
        board.report(["a": .active], from: "relay")
        board.report(["a": .active], from: "agents")
        XCTAssertEqual(published, [["a": .idle], ["a": .active]])
    }

    // MARK: - Owned sources

    private final class Source: ProviderActivitySource {
        let providerIDs: Set<String>
        @Published var states: [String: ProviderActivityState] = [:]
        var statesPublisher: AnyPublisher<[String: ProviderActivityState], Never> {
            $states.eraseToAnyPublisher()
        }
        var starts = 0
        var stops = 0
        init(_ ids: Set<String>) { providerIDs = ids }
        func start() { starts += 1 }
        func stop() { stops += 1 }
    }

    private func settle() async {
        // Owned sources deliver on the main queue, like the notch's monitors.
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))
    }

    /// A source runs while any provider it speaks for is actually consumed by
    /// the status item, and only consumed states get through.
    func testAnOwnedSourceRunsOnlyWhileOneOfItsProvidersIsConsumed() async {
        let source = Source(["glm", "opencode"])
        let board = ProviderActivityBoard()
        board.add(source, as: "opencode")
        XCTAssertEqual(source.starts, 0, "nothing connected, nothing started")

        board.setConsumed(["glm"])
        XCTAssertEqual(source.starts, 1)
        source.states = ["glm": .active, "opencode": .active]
        await settle()
        XCTAssertEqual(board.state(for: "glm"), .active)
        XCTAssertEqual(board.state(for: "opencode"), .unknown, "not connected, so not reported")

        board.setConsumed(["glm", "opencode"])
        XCTAssertEqual(source.starts, 1, "already running")
        XCTAssertEqual(board.state(for: "opencode"), .active)

        board.setConsumed(["claude"])
        XCTAssertEqual(source.stops, 1)
        XCTAssertEqual(board.states, [:], "a stopped source's states are withdrawn")
        source.states = ["glm": .active]
        await settle()
        XCTAssertEqual(board.state(for: "glm"), .unknown, "a late publication cannot bring it back")
    }

    func testMonitorSourceReducesSessionsForItsProvider() async {
        final class Monitor: AgentActivityMonitor {
            @Published var sessions: [AgentSession] = []
            var sessionsPublisher: AnyPublisher<[AgentSession], Never> { $sessions.eraseToAnyPublisher() }
            var running = false
            func start() { running = true }
            func stop() { running = false }
        }
        let monitor = Monitor()
        let board = ProviderActivityBoard()
        board.add(MonitorActivitySource(providerID: "copilot", monitor: monitor), as: "copilot")
        board.setConsumed(["copilot"])
        XCTAssertTrue(monitor.running)
        await settle()
        XCTAssertEqual(board.state(for: "copilot"), .idle, "running and seeing nothing")
        monitor.sessions = [session(.busy)]
        await settle()
        XCTAssertEqual(board.state(for: "copilot"), .active)
        board.stop()
        XCTAssertFalse(monitor.running)
        XCTAssertEqual(board.state(for: "copilot"), .unknown)
    }

    // MARK: - The notch's monitors

    /// The coordinator's monitors reach the board as they are, and one that is
    /// switched off drops out rather than reading as idle.
    func testTheCoordinatorReportsOnlyRunningMonitors() {
        final class Monitor: AgentActivityMonitor {
            @Published var sessions: [AgentSession] = []
            var sessionsPublisher: AnyPublisher<[AgentSession], Never> { $sessions.eraseToAnyPublisher() }
            func start() {}
            func stop() {}
        }
        let claude = Monitor(), codex = Monitor()
        let coordinator = ActivityCoordinator(monitors: ["claude": claude, "codex": codex]) { _, _ in }
        coordinator.setEnabled(["claude", "codex"])
        claude.sessions = [session(.busy)]
        codex.sessions = [session(.waiting)]
        XCTAssertEqual(coordinator.activityStates, ["claude": .active, "codex": .idle])
        coordinator.setEnabled(["claude"])
        XCTAssertEqual(coordinator.activityStates, ["claude": .active])
        coordinator.stop()
        XCTAssertEqual(coordinator.activityStates, [:])
    }
}
