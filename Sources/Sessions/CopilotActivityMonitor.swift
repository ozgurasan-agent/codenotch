import Combine
import CoreServices
import Darwin
import Foundation

/// The monitor only needs one recursive resource, regardless of how many old
/// sessions Copilot has accumulated beneath its session-state directory.
@MainActor
protocol CopilotFileEventWatching: AnyObject {
    var isWatching: Bool { get }
    var resourceCount: Int { get }
    func start(path: String, onEvent: @escaping @MainActor (_ requiresRecreation: Bool) -> Void) -> Bool
    func stop()
}

/// A small owner around CoreServices' recursive FSEventStream API.
///
/// The SDK contract requires a scheduled stream to be invalidated before it is
/// released, and only permits `Stop` after a successful `Start`. Keeping the
/// callback box alive until after all three calls makes the context's
/// unretained `info` pointer valid for every possible callback.
@MainActor
final class CoreServicesCopilotFileEventWatcher: CopilotFileEventWatching {
    private final class CallbackBox: @unchecked Sendable {
        let handler: @MainActor (Bool) -> Void

        init(handler: @escaping @MainActor (Bool) -> Void) {
            self.handler = handler
        }
    }

    private var stream: FSEventStreamRef?
    private var callbackBox: CallbackBox?

    var isWatching: Bool { stream != nil }
    var resourceCount: Int { stream == nil ? 0 : 1 }

    func start(path: String, onEvent: @escaping @MainActor (Bool) -> Void) -> Bool {
        stop()

        let box = CallbackBox(handler: onEvent)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, eventCount, _, eventFlags, _ in
            guard let info else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
            let recreateMask = FSEventStreamEventFlags(
                kFSEventStreamEventFlagUserDropped
                    | kFSEventStreamEventFlagKernelDropped
                    | kFSEventStreamEventFlagEventIdsWrapped
                    | kFSEventStreamEventFlagRootChanged
            )
            var requiresRecreation = false
            for index in 0..<eventCount where eventFlags[index] & recreateMask != 0 {
                requiresRecreation = true
                break
            }
            // This stream is scheduled on the main queue. The callback itself
            // only asks the monitor to debounce a scan; stream teardown happens
            // later, outside this CoreServices callback frame.
            MainActor.assumeIsolated {
                box.handler(requiresRecreation)
            }
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagFileEvents
        )
        guard let created = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,
            flags
        ) else { return false }

        callbackBox = box
        FSEventStreamSetDispatchQueue(created, .main)
        guard FSEventStreamStart(created) else {
            // `Start` failed, so calling `Stop` would violate the API contract.
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            callbackBox = nil
            return false
        }
        stream = created
        return true
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        callbackBox = nil
    }

    deinit {
        // Instances are main-actor owned and the monitor always calls `stop`.
        // Keep a defensive release for an owner that forgets to do so.
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

/// Notices when GitHub Copilot's agent is mid-turn.
///
/// The Copilot CLI — standalone, or run by VS Code for its Copilot CLI
/// sessions — keeps an event log per session in
/// `~/.copilot/session-state/<id>/events.jsonl`, and the log records the
/// turn's own boundaries rather than leaving recency to stand in for them:
///
/// ```
/// user.message → assistant.turn_start → assistant.message {toolRequests: [1]}
///   → tool.execution_start → tool.execution_complete → assistant.turn_end
///   → assistant.turn_start → assistant.message {toolRequests: []}
///   → assistant.turn_end → session.shutdown
/// ```
///
/// A turn that ends having asked for tools is followed at once by another, so
/// the work is over only when a turn ends with none — or when the session says
/// it is idle, or shuts down.
///
/// The log names no process, so a CLI killed mid-turn leaves one that says
/// "working" for ever. The CLI's own process logs,
/// `~/.copilot/logs/process-<start ms>-<pid>.log`, say whether any Copilot CLI
/// is alive at all. `staleAfter` is an admission gate for a log the monitor has
/// never observed: once a live turn is known, it remains live through a long
/// quiet think or build until a boundary is written or the CLI exits.
///
/// Copilot Chat's own agent in VS Code, inline completions and the JetBrains
/// plugins write nothing on disk that says a request is in flight, so they are
/// not seen here.
@MainActor
final class CopilotActivityMonitor: ObservableObject, AgentActivityMonitor {
    @Published private(set) var sessions: [AgentSession] = []
    var sessionsPublisher: AnyPublisher<[AgentSession], Never> { $sessions.eraseToAnyPublisher() }

    private let root: URL
    private let interval: TimeInterval
    private let staleAfter: TimeInterval
    private let watcher: CopilotFileEventWatching
    private let cliIsRunning: () -> Bool
    private var timer: Timer?
    private var debounce: DispatchWorkItem?
    private var scanRequested = false
    private var watcherRecreationRequested = false
    private var isStarted = false
    private var watcherGeneration: UInt = 0
    private var nextWatcherRetry = Date.distantPast
    private var lastFallbackScan: Date?
    private var rootWasMissing = false
    private var observedBusySessionIDs: Set<String> = []
    private let fallbackScanInterval: TimeInterval = 30
    /// Observable to focused tests: idle timer ticks must not turn into full
    /// directory scans when no filesystem event has happened.
    private(set) var scanCount = 0
    var watcherResourceCount: Int { watcher.resourceCount }

    init(root: URL = CopilotActivity.sessionsRoot,
         logs: URL = CopilotActivity.logsDirectory,
         interval: TimeInterval = 2,
         staleAfter: TimeInterval = 5 * 60,
         watcher: CopilotFileEventWatching? = nil,
         cliIsRunning: (() -> Bool)? = nil) {
        self.root = root
        self.interval = interval
        self.staleAfter = staleAfter
        self.watcher = watcher ?? CoreServicesCopilotFileEventWatcher()
        self.cliIsRunning = cliIsRunning ?? { CopilotActivity.isCLIRunning(logs: logs) }
    }

    func start() {
        stop()
        isStarted = true
        scanRequested = true
        poll()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        isStarted = false
        watcherGeneration &+= 1
        timer?.invalidate()
        timer = nil
        debounce?.cancel()
        debounce = nil
        watcher.stop()
        scanRequested = false
        watcherRecreationRequested = false
        nextWatcherRetry = .distantPast
        lastFallbackScan = nil
        rootWasMissing = false
    }

    /// Timer ticks do one cheap root metadata check until a watcher can be
    /// installed, and one cheap process-liveness check while work is active.
    /// Full history enumeration only follows an event or the throttled failure
    /// fallback; unchanged two-second ticks never scan hundreds of sessions.
    func poll(now: Date = Date()) {
        guard isStarted else { return }

        if watcherRecreationRequested {
            watcherRecreationRequested = false
            watcherGeneration &+= 1
            watcher.stop()
            nextWatcherRetry = .distantPast
        }
        let rootExists = watcher.isWatching ? true : installWatcherIfPossible(now: now)

        if scanRequested {
            rescan(now: now)
            return
        }

        if !watcher.isWatching,
           rootExists,
           lastFallbackScan.map({ now.timeIntervalSince($0) >= fallbackScanInterval }) ?? true {
            // Apple's documented fallback when stream creation/start fails.
            // Keep it well away from the normal two-second polling cadence.
            rescan(now: now)
            return
        }

        if !sessions.isEmpty, !cliIsRunning() {
            sessions = []
            observedBusySessionIDs = []
        }
    }

    private func rescan(now: Date) {
        let eventLogs = CopilotActivity.eventLogs(root: root)
        scanCount += 1
        scanRequested = false
        let found = CopilotActivity.read(eventLogs: eventLogs, staleAfter: staleAfter, now: now,
                                         retaining: observedBusySessionIDs,
                                         isCLIRunning: cliIsRunning)
        if !watcher.isWatching { lastFallbackScan = now }
        observedBusySessionIDs = Set(found.map(\.id))
        guard found != sessions else { return }
        sessions = found
    }

    /// Returns whether the root exists so a watcher-less tick does not repeat
    /// the same metadata lookup when considering its fallback scan.
    private func installWatcherIfPossible(now: Date) -> Bool {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            rootWasMissing = true
            return false
        }
        if rootWasMissing {
            rootWasMissing = false
            nextWatcherRetry = .distantPast
        }
        guard now >= nextWatcherRetry else { return true }

        watcherGeneration &+= 1
        let generation = watcherGeneration
        if watcher.start(path: root.path, onEvent: { [weak self] requiresRecreation in
            guard let self, self.isStarted, self.watcherGeneration == generation else { return }
            self.scheduleRescan(recreateWatcher: requiresRecreation)
        }) {
            scanRequested = true
            nextWatcherRetry = .distantPast
        } else {
            // Creating/starting a failed stream on every two-second tick is
            // needless churn. Retry alongside the documented scan fallback.
            nextWatcherRetry = now.addingTimeInterval(fallbackScanInterval)
        }
        return true
    }

    private func scheduleRescan(recreateWatcher: Bool) {
        scanRequested = true
        watcherRecreationRequested = watcherRecreationRequested || recreateWatcher
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.poll() }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }
}

enum CopilotActivity {
    struct EventLog {
        let name: String
        let path: String
    }

    static var sessionsRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".copilot/session-state")
    }

    static var logsDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".copilot/logs")
    }

    /// Every session whose log says a turn is running. `isCLIRunning` is only
    /// asked when one does, so an idle Mac never looks at the process table.
    static func read(root: URL, staleAfter: TimeInterval, now: Date = Date(),
                     retaining observedBusySessionIDs: Set<String> = [],
                     isCLIRunning: () -> Bool = { true }) -> [AgentSession] {
        read(eventLogs: eventLogs(root: root), staleAfter: staleAfter, now: now,
             retaining: observedBusySessionIDs, isCLIRunning: isCLIRunning)
    }

    static func eventLogs(root: URL) -> [EventLog] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.map { name in
            EventLog(name: name, path: root.path + "/" + name + "/events.jsonl")
        }
    }

    static func read(eventLogs: [EventLog], staleAfter: TimeInterval, now: Date = Date(),
                     retaining observedBusySessionIDs: Set<String> = [],
                     isCLIRunning: () -> Bool = { true }) -> [AgentSession] {
        var found: [AgentSession] = []
        for eventLog in eventLogs {
            let id = "copilot.\(eventLog.name)"
            let directory = URL(fileURLWithPath: eventLog.path).deletingLastPathComponent().path
            // `stat`, not `attributesOfItem`: one syscall per session on every
            // requested scan, the same economy `AntigravityActivityMonitor`
            // keeps. Idle timer ticks never reach this loop.
            var info = stat()
            guard stat(eventLog.path, &info) == 0 else { continue }
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
            // Age rejects never-observed historical logs, not a known live
            // turn: thinking and long-running tools can legitimately be quiet
            // for much longer than the admission window.
            guard now.timeIntervalSince(modified) <= staleAfter || observedBusySessionIDs.contains(id),
                  let tail = tail(of: eventLog.path),
                  case .working(let since)? = turn(inTail: tail)
            else { continue }
            found.append(AgentSession(
                id: id,
                name: folder(of: directory) ?? "Copilot",
                detail: L10n.t("Working"),
                state: .busy,
                waitingFor: nil,
                since: since ?? modified
            ))
        }
        guard !found.isEmpty, isCLIRunning() else { return [] }
        return found.sorted { $0.since == $1.since ? $0.id < $1.id : $0.since > $1.since }
    }

    /// What the newest turn in a log is doing.
    enum Turn: Equatable {
        /// Since the prompt that started it, when the tail still holds it.
        case working(since: Date?)
        /// Finished, stopped, or waiting at the prompt.
        case idle
        /// The session shut down.
        case ended
    }

    /// Records written between a turn's boundaries — thinking, streaming, a
    /// sub-agent — that say work is under way but not where the turn stands.
    private static let inFlight: Set<String> = [
        "assistant.intent", "assistant.reasoning", "assistant.reasoning_delta",
        "assistant.message_delta", "assistant.usage", "subagent.started", "subagent.completed",
    ]

    private typealias Record = (type: String, data: [String: Any], timestamp: String?)

    /// The newest records decide, walking back from the end of the log.
    static func turn(inTail data: Data) -> Turn? {
        var records: [Record] = []
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            // A tail's first line is usually cut in half; it fails to parse and
            // is skipped, which is all it deserves.
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            records.append((type, object["data"] as? [String: Any] ?? [:], object["timestamp"] as? String))
        }
        /// Set on meeting the newest `turn_end`: from there back, the question
        /// is only whether the turn that ended asked for tools.
        var turnEnded = false
        for (index, record) in records.enumerated().reversed() {
            let working = { Turn.working(since: promptTime(in: records[...index])) }
            switch record.type {
            case "session.shutdown":
                return .ended
            case "session.idle", "abort":
                return .idle
            case "assistant.turn_end":
                turnEnded = true
            case "assistant.message":
                guard turnEnded else { return working() }
                // A turn that ends asking for tools is followed at once by
                // another; one that ends with an answer is the end of the work.
                let requests = record.data["toolRequests"] as? [Any] ?? []
                return requests.isEmpty ? .idle : working()
            case let type where type.hasPrefix("tool."):
                // Running now, or run inside the turn that just ended — which
                // means it asked for them and the next turn is on its way.
                return working()
            case "user.message", "assistant.turn_start":
                // Reached with the turn over and no message on the way back: it
                // was cut short.
                return turnEnded ? .idle : working()
            case let type where inFlight.contains(type):
                guard turnEnded else { return working() }
            default:
                continue
            }
        }
        return nil
    }

    /// When the prompt behind this interaction was sent, when the tail still
    /// holds it.
    private static func promptTime(in records: ArraySlice<Record>) -> Date? {
        records.last { $0.type == "user.message" }?.timestamp.flatMap(date)
    }

    /// Whether any Copilot CLI is alive, going by the logs each one writes as
    /// `process-<start ms>-<pid>.log`. With no such logs at all — an install
    /// that keeps them elsewhere — nothing can be proved dead, so the answer is
    /// yes and staleness alone decides.
    static func isCLIRunning(logs: URL) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: logs.path) else { return true }
        let processes = names.compactMap(process(fromLogName:))
        guard !processes.isEmpty else { return true }
        return processes.contains { ProcessLiveness.isAlive(pid: $0.pid, startedAt: $0.startedAt) }
    }

    static func process(fromLogName name: String) -> (pid: Int32, startedAt: Date)? {
        guard name.hasPrefix("process-"), name.hasSuffix(".log") else { return nil }
        let parts = name.dropFirst("process-".count).dropLast(".log".count).split(separator: "-")
        guard parts.count == 2, let millis = Double(parts[0]), let pid = Int32(parts[1]), pid > 0 else { return nil }
        return (pid, Date(timeIntervalSince1970: millis / 1000))
    }

    /// The folder the session runs in, from the `cwd:` line of its
    /// `workspace.yaml` — the name a tooltip would use for it.
    private static func folder(of directory: String) -> String? {
        guard let text = try? String(contentsOfFile: directory + "/workspace.yaml", encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("cwd:") {
            let path = line.dropFirst(4).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            let name = URL(fileURLWithPath: path).lastPathComponent
            return name.isEmpty || path.isEmpty ? nil : name
        }
        return nil
    }

    /// The last 64 KB is plenty: a turn's boundaries are one line each.
    private static let tailBytes: UInt64 = 65_536

    private static func tail(of path: String) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        guard (try? handle.seek(toOffset: end > tailBytes ? end - tailBytes : 0)) != nil else { return nil }
        return try? handle.readToEnd()
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
