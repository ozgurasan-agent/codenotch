import XCTest
@testable import Codenotch

@MainActor
private final class TestCopilotFileEventWatcher: CopilotFileEventWatching {
    var startSucceeds = true
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var handler: (@MainActor (Bool) -> Void)?
    private var lastHandler: (@MainActor (Bool) -> Void)?

    var isWatching: Bool { handler != nil }
    var resourceCount: Int { isWatching ? 1 : 0 }

    func start(path _: String, onEvent: @escaping @MainActor (Bool) -> Void) -> Bool {
        startCount += 1
        guard startSucceeds else { return false }
        handler = onEvent
        lastHandler = onEvent
        return true
    }

    func stop() {
        stopCount += 1
        handler = nil
    }

    func emit(requiresRecreation: Bool = false) {
        handler?(requiresRecreation)
    }

    /// Simulates an already-queued callback arriving after the owner stopped.
    func emitStaleCallback() {
        lastHandler?(false)
    }
}

private final class MutableBool: @unchecked Sendable {
    var value: Bool
    init(_ value: Bool) { self.value = value }
}

/// Copilot's agent writes its turn boundaries into each session's event log;
/// these fixtures follow the order a real session wrote them in.
final class CopilotActivityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_000_000)
    private var directories: [URL] = []

    override func tearDownWithError() throws {
        for url in directories { try? FileManager.default.removeItem(at: url) }
        directories = []
    }

    private func stamp(_ offset: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: now.addingTimeInterval(offset))
    }

    /// One event per line, the shape the CLI writes.
    private func event(_ type: String, at offset: TimeInterval = 0, tools: Int? = nil) -> String {
        var data = "{}"
        if let tools {
            let requests = Array(repeating: #"{"toolCallId":"t","name":"bash"}"#, count: tools)
            data = #"{"content":"","toolRequests":[\#(requests.joined(separator: ","))]}"#
        }
        return #"{"type":"\#(type)","data":\#(data),"id":"\#(UUID().uuidString)","timestamp":"\#(stamp(offset))","parentId":null}"#
    }

    private func turn(_ events: [String]) -> CopilotActivity.Turn? {
        CopilotActivity.turn(inTail: Data(events.joined(separator: "\n").utf8))
    }

    // MARK: - Reading a log

    func testAPromptJustSentIsWork() {
        XCTAssertEqual(turn([event("session.start"), event("user.message", at: -3)]),
                       .working(since: now.addingTimeInterval(-3)))
    }

    /// Thinking, asking for a tool, running it: all one interaction in flight.
    func testEveryStepOfATurnIsWork() {
        let steps = [event("session.start"), event("user.message", at: -9), event("assistant.turn_start", at: -8),
                     event("assistant.message", at: -6, tools: 1), event("tool.execution_start", at: -5)]
        for count in 3...steps.count {
            XCTAssertEqual(turn(Array(steps.prefix(count))), .working(since: now.addingTimeInterval(-9)),
                           "after \(count) records")
        }
    }

    /// A turn that ends having asked for tools is followed at once by
    /// another, so it is not the end of the work.
    func testATurnThatEndedAskingForToolsIsStillWork() {
        XCTAssertEqual(turn([event("user.message", at: -9), event("assistant.turn_start"),
                             event("assistant.message", tools: 1), event("tool.execution_start"),
                             event("tool.execution_complete"), event("assistant.turn_end")]),
                       .working(since: now.addingTimeInterval(-9)))
        XCTAssertEqual(turn([event("user.message"), event("assistant.turn_start"),
                             event("assistant.message", tools: 2), event("assistant.turn_end")]),
                       .working(since: now))
    }

    /// The answer with no tools asked for is the end of the work — the exact
    /// sequence a real session ends on.
    func testATurnThatEndsWithAnAnswerIsIdle() {
        XCTAssertEqual(turn([event("user.message"), event("assistant.turn_start"),
                             event("assistant.message", tools: 1), event("tool.execution_start"),
                             event("tool.execution_complete"), event("assistant.turn_end"),
                             event("assistant.turn_start"), event("assistant.message", tools: 0),
                             event("assistant.turn_end")]),
                       .idle)
        XCTAssertEqual(turn([event("user.message"), event("assistant.turn_start"),
                             event("assistant.message", tools: 0), event("assistant.usage"),
                             event("assistant.turn_end")]),
                       .idle, "a record written after the answer does not reopen it")
    }

    func testShutdownIdleAndAbortEndTheWork() {
        XCTAssertEqual(turn([event("user.message"), event("assistant.turn_start"), event("session.shutdown")]), .ended)
        XCTAssertEqual(turn([event("user.message"), event("assistant.turn_start"), event("session.idle")]), .idle)
        XCTAssertEqual(turn([event("user.message"), event("assistant.turn_start"), event("abort")]), .idle)
        XCTAssertEqual(turn([event("session.resume"), event("system.message")]), nil,
                       "a resumed session nobody has spoken to yet has no turn")
    }

    /// The first line of a tail is usually cut in half; it is skipped.
    func testAHalfLineIsSkipped() {
        let log = "e\",\"data\":{}}\n" + event("user.message")
        XCTAssertEqual(CopilotActivity.turn(inTail: Data(log.utf8)), .working(since: now))
    }

    // MARK: - Reading sessions

    private func makeRoot(_ sessions: [(name: String, events: [String], modified: TimeInterval, cwd: String?)]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("copilot-\(UUID().uuidString)")
        directories.append(root)
        for session in sessions {
            let directory = root.appendingPathComponent(session.name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let log = directory.appendingPathComponent("events.jsonl")
            try Data(session.events.joined(separator: "\n").utf8).write(to: log)
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(session.modified)], ofItemAtPath: log.path)
            if let cwd = session.cwd {
                try Data("id: \(session.name)\ncwd: \(cwd)\nname: x\n".utf8)
                    .write(to: directory.appendingPathComponent("workspace.yaml"))
            }
        }
        return root
    }

    func testOnlySessionsInTheMiddleOfATurnAreReported() throws {
        let root = try makeRoot([
            ("busy", [event("user.message", at: -20), event("assistant.turn_start", at: -19)], -2, "/Users/x/Projects/codenotch"),
            ("done", [event("user.message"), event("assistant.message", tools: 0), event("assistant.turn_end")], -1, nil),
            ("closed", [event("user.message"), event("session.shutdown")], -1, nil),
            ("stale", [event("user.message", at: -900)], -900, nil),
        ])
        let sessions = CopilotActivity.read(root: root, staleAfter: 300, now: now)
        XCTAssertEqual(sessions.map(\.id), ["copilot.busy"])
        XCTAssertEqual(sessions.first?.state, .busy)
        XCTAssertEqual(sessions.first?.name, "codenotch", "named after the folder it runs in")
        XCTAssertEqual(sessions.first?.since, now.addingTimeInterval(-20))
    }

    /// With no Copilot CLI alive, no log can be a turn in progress, however
    /// fresh — a CLI killed mid-turn never writes that it stopped.
    func testNoLiveCLIMeansNoWork() throws {
        let root = try makeRoot([("busy", [event("user.message")], -1, nil)])
        XCTAssertTrue(CopilotActivity.read(root: root, staleAfter: 300, now: now, isCLIRunning: { false }).isEmpty)
        XCTAssertEqual(CopilotActivity.read(root: root, staleAfter: 300, now: now, isCLIRunning: { true }).count, 1)
    }

    func testAMissingDirectoryIsNothingRunning() {
        let missing = URL(fileURLWithPath: "/nonexistent/copilot-\(UUID().uuidString)")
        XCTAssertTrue(CopilotActivity.read(root: missing, staleAfter: 300, now: now).isEmpty)
    }

    /// Once an idle scan has installed its one recursive watcher, unchanged
    /// timer ticks do not enumerate/stat every historical session again. A
    /// write anywhere below the root still requests a complete scan.
    @MainActor
    func testIdlePollsSkipScansUntilAnEventLogChanges() throws {
        let root = try makeRoot([(
            "session", [event("user.message"), event("assistant.message", tools: 0),
                        event("assistant.turn_end")], 0, nil
        )])
        let logs = root.deletingLastPathComponent().appendingPathComponent("missing-process-logs")
        let watcher = TestCopilotFileEventWatcher()
        let monitor = CopilotActivityMonitor(root: root, logs: logs, interval: 3600, staleAfter: 300,
                                             watcher: watcher)
        monitor.start()
        defer { monitor.stop() }

        XCTAssertTrue(monitor.sessions.isEmpty)
        let initialScans = monitor.scanCount
        monitor.poll()
        monitor.poll()
        XCTAssertEqual(monitor.scanCount, initialScans,
                       "unchanged idle ticks stop before root enumeration")

        let path = root.appendingPathComponent("session/events.jsonl")
        let handle = try FileHandle(forWritingTo: path)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(("\n" + event("user.message", at: 1)).utf8))
        try handle.close()

        watcher.emit()
        monitor.poll()
        XCTAssertGreaterThan(monitor.scanCount, initialScans)
        XCTAssertEqual(monitor.sessions.map(\.id), ["copilot.session"],
                       "the filesystem event makes new work visible")
    }

    @MainActor
    func testHundredsOfHistoricalSessionsUseOneRecursiveResourceAndResumeTheOldest() throws {
        let sessionCount = 320
        let historical = (0..<sessionCount).map { index in
            (name: String(format: "session-%03d", index),
             events: [event("user.message"), event("assistant.message", tools: 0), event("assistant.turn_end")],
             modified: TimeInterval(-index), cwd: Optional<String>.none)
        }
        let oldestSession = try XCTUnwrap(historical.min { $0.modified < $1.modified })
        XCTAssertEqual(oldestSession.name, "session-319", "the fixture's final entry is its oldest")
        let root = try makeRoot(historical)
        let watcher = TestCopilotFileEventWatcher()
        let monitor = CopilotActivityMonitor(root: root, interval: 3600, watcher: watcher,
                                             cliIsRunning: { true })
        monitor.start()
        defer { monitor.stop() }

        XCTAssertEqual(watcher.startCount, 1)
        XCTAssertEqual(monitor.watcherResourceCount, 1)
        let initialScans = monitor.scanCount
        monitor.poll()
        monitor.poll()
        XCTAssertEqual(monitor.scanCount, initialScans)

        let oldest = root.appendingPathComponent("\(oldestSession.name)/events.jsonl")
        let handle = try FileHandle(forWritingTo: oldest)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(("\n" + event("session.resume") + "\n" + event("user.message")).utf8))
        try handle.close()
        watcher.emit()
        monitor.poll()
        XCTAssertEqual(monitor.sessions.map(\.id), ["copilot.\(oldestSession.name)"],
                       "the oldest resumed log remains visible through the one root stream")

        watcher.emit(requiresRecreation: true)
        monitor.poll()
        XCTAssertEqual(watcher.startCount, 2, "dropped/root-change events recreate outside the callback")
        XCTAssertEqual(monitor.watcherResourceCount, 1)
    }

    @MainActor
    func testStopRejectsQueuedCallbacksAndRestartImmediatelyRescans() throws {
        let root = try makeRoot([(
            "session", [event("user.message"), event("assistant.message", tools: 0),
                        event("assistant.turn_end")], 0, nil
        )])
        let watcher = TestCopilotFileEventWatcher()
        let monitor = CopilotActivityMonitor(root: root, interval: 3600, watcher: watcher,
                                             cliIsRunning: { true })
        monitor.start()
        let scansBeforeStop = monitor.scanCount
        monitor.stop()

        watcher.emitStaleCallback()
        monitor.poll()
        XCTAssertEqual(monitor.scanCount, scansBeforeStop)
        XCTAssertEqual(monitor.watcherResourceCount, 0)

        let path = root.appendingPathComponent("session/events.jsonl")
        let handle = try FileHandle(forWritingTo: path)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(("\n" + event("user.message")).utf8))
        try handle.close()

        monitor.start()
        defer { monitor.stop() }
        XCTAssertEqual(monitor.sessions.map(\.id), ["copilot.session"],
                       "restart scans even though no stopped-stream callback was accepted")
    }

    @MainActor
    func testMissingRootCreationInstallsWatcherAndFindsWork() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("copilot-missing-\(UUID().uuidString)")
        directories.append(root)
        let watcher = TestCopilotFileEventWatcher()
        let monitor = CopilotActivityMonitor(root: root, interval: 3600, watcher: watcher,
                                             cliIsRunning: { true })
        monitor.start()
        defer { monitor.stop() }
        XCTAssertEqual(watcher.startCount, 0)
        XCTAssertEqual(monitor.watcherResourceCount, 0)

        let session = root.appendingPathComponent("new-session")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try Data(event("user.message").utf8).write(to: session.appendingPathComponent("events.jsonl"))
        monitor.poll()

        XCTAssertEqual(watcher.startCount, 1)
        XCTAssertEqual(monitor.watcherResourceCount, 1)
        XCTAssertEqual(monitor.sessions.map(\.id), ["copilot.new-session"])
    }

    @MainActor
    func testKnownQuietTurnSurvivesAdmissionAgeUntilCLIDies() throws {
        let root = try makeRoot([("busy", [event("user.message")], 0, nil)])
        let eventLog = root.appendingPathComponent("busy/events.jsonl")
        let started = Date()
        try FileManager.default.setAttributes([.modificationDate: started], ofItemAtPath: eventLog.path)
        let live = MutableBool(true)
        let monitor = CopilotActivityMonitor(root: root, interval: 3600, staleAfter: 300,
                                             watcher: TestCopilotFileEventWatcher(),
                                             cliIsRunning: { live.value })
        monitor.start()
        defer { monitor.stop() }
        XCTAssertEqual(monitor.sessions.map(\.id), ["copilot.busy"])

        monitor.poll(now: started.addingTimeInterval(10 * 60))
        XCTAssertEqual(monitor.sessions.map(\.id), ["copilot.busy"],
                       "a known live turn is not expired merely because its log is quiet")

        live.value = false
        monitor.poll(now: started.addingTimeInterval(10 * 60 + 2))
        XCTAssertTrue(monitor.sessions.isEmpty)
    }

    func testAncientNeverObservedTurnIsNotRevived() throws {
        let root = try makeRoot([("ancient", [event("user.message", at: -900)], -900, nil)])
        XCTAssertTrue(CopilotActivity.read(root: root, staleAfter: 300, now: now,
                                           retaining: ["copilot.some-other-session"]).isEmpty)
        XCTAssertEqual(CopilotActivity.read(root: root, staleAfter: 300, now: now,
                                            retaining: ["copilot.ancient"]).map(\.id),
                       ["copilot.ancient"], "only an actually observed id may pass the age gate")
    }

    @MainActor
    func testFailedWatcherFallsBackNoMoreThanEveryThirtySeconds() throws {
        let root = try makeRoot([(
            "session", [event("user.message"), event("assistant.message", tools: 0),
                        event("assistant.turn_end")], 0, nil
        )])
        let watcher = TestCopilotFileEventWatcher()
        watcher.startSucceeds = false
        let monitor = CopilotActivityMonitor(root: root, interval: 3600, watcher: watcher,
                                             cliIsRunning: { true })
        let baseline = Date()
        monitor.start()
        defer { monitor.stop() }
        let initialScans = monitor.scanCount

        monitor.poll(now: baseline.addingTimeInterval(2))
        monitor.poll(now: baseline.addingTimeInterval(29))
        XCTAssertEqual(monitor.scanCount, initialScans)
        monitor.poll(now: baseline.addingTimeInterval(31))
        XCTAssertEqual(monitor.scanCount, initialScans + 1)
    }

    /// Exercises the production CoreServices owner independently of the fake
    /// used for deterministic monitor tests. Start/stop/restart must always
    /// expose zero or one live stream and repeated stop must be idempotent.
    @MainActor
    func testProductionFSEventWrapperLifecycleIsBoundedAndRestartable() throws {
        let root = try makeRoot([])
        let watcher = CoreServicesCopilotFileEventWatcher()
        XCTAssertTrue(watcher.start(path: root.path, onEvent: { _ in }))
        XCTAssertEqual(watcher.resourceCount, 1)
        watcher.stop()
        XCTAssertEqual(watcher.resourceCount, 0)
        watcher.stop()
        XCTAssertEqual(watcher.resourceCount, 0)
        XCTAssertTrue(watcher.start(path: root.path, onEvent: { _ in }))
        XCTAssertEqual(watcher.resourceCount, 1)
        watcher.stop()
        XCTAssertEqual(watcher.resourceCount, 0)
    }

    // MARK: - Whether a CLI is alive

    func testProcessLogNamesCarryTheStartAndThePid() throws {
        let parsed = try XCTUnwrap(CopilotActivity.process(fromLogName: "process-1789627570281-34478.log"))
        XCTAssertEqual(parsed.pid, 34478)
        XCTAssertEqual(parsed.startedAt.timeIntervalSince1970, 1_789_627_570.281, accuracy: 0.001)
        for name in [".copilot-log.lock", "process-abc-12.log", "process-1789627570281.log", "session.log"] {
            XCTAssertNil(CopilotActivity.process(fromLogName: name), name)
        }
    }

    func testTheCLIIsAliveOnlyWhileAProcessFromItsLogsIs() throws {
        let logs = FileManager.default.temporaryDirectory.appendingPathComponent("copilot-logs-\(UUID().uuidString)")
        directories.append(logs)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        XCTAssertTrue(CopilotActivity.isCLIRunning(logs: logs), "no logs to go by proves nothing dead")

        // A pid that cannot exist.
        try Data().write(to: logs.appendingPathComponent("process-1789627570281-999999.log"))
        XCTAssertFalse(CopilotActivity.isCLIRunning(logs: logs))

        // This test's own process, with its real start time.
        let pid = ProcessInfo.processInfo.processIdentifier
        let started = try XCTUnwrap(ProcessLiveness.startTime(pid: pid))
        try Data().write(to: logs.appendingPathComponent(
            "process-\(Int(started.timeIntervalSince1970 * 1000))-\(pid).log"))
        XCTAssertTrue(CopilotActivity.isCLIRunning(logs: logs))
    }
}
