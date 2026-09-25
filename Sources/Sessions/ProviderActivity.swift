import Combine
import Foundation

/// Whether a provider is doing AI work right now, however that was found out.
///
/// Every source says it its own way — a session registry, a turn marker in a
/// log, a request passing through the relay — and this is the one shape they
/// are all reduced to, so whatever shows it never has to know how a provider
/// was read.
enum ProviderActivityState: Equatable {
    /// A turn is running or a request is in flight.
    case active
    /// Something is watching and sees nothing in flight — which includes a
    /// session sitting at its prompt, or blocked waiting on an answer from you.
    case idle
    /// Nothing is watching: the provider has no activity source, or its source
    /// is switched off. Never shown as more than idle.
    case unknown

    /// Only `busy` is work in flight. `waiting` is stopped on a question and
    /// `success` has just ended; neither is the provider spending anything.
    init(sessions: [AgentSession]) {
        self = sessions.contains { $0.state == .busy } ? .active : .idle
    }

    /// Several sources' answers as one: any that sees work wins, then any that
    /// is watching at all.
    static func merged<S: Sequence>(_ states: S) -> ProviderActivityState
    where S.Element == ProviderActivityState {
        var result = ProviderActivityState.unknown
        for state in states {
            if state == .active { return .active }
            if state == .idle { result = .idle }
        }
        return result
    }
}

/// Something that can say what one or more providers are doing, for sources
/// whose only reader is `ProviderActivityBoard`. The board starts one only
/// while one of its provider marks is actually consumed by the menu bar.
@MainActor
protocol ProviderActivitySource: AnyObject {
    /// Every provider this source can speak for.
    var providerIDs: Set<String> { get }
    var statesPublisher: AnyPublisher<[String: ProviderActivityState], Never> { get }
    func start()
    func stop()
}

/// One `AgentActivityMonitor` as the source for one provider.
@MainActor
final class MonitorActivitySource: ProviderActivitySource {
    let providerIDs: Set<String>
    private let providerID: String
    private let monitor: any AgentActivityMonitor

    init(providerID: String, monitor: any AgentActivityMonitor) {
        self.providerID = providerID
        self.providerIDs = [providerID]
        self.monitor = monitor
    }

    var statesPublisher: AnyPublisher<[String: ProviderActivityState], Never> {
        let id = providerID
        return monitor.sessionsPublisher
            .map { [id: ProviderActivityState(sessions: $0)] }
            .eraseToAnyPublisher()
    }

    func start() { monitor.start() }
    func stop() { monitor.stop() }
}

/// Every provider's activity in one place, merged from every source that has
/// something to say about it.
///
/// Two kinds of source report here. The notch's monitors, the Ollama relay and
/// LM Studio's socket already run for reasons of their own, and are only
/// listened to (`report`). Sources that exist for this alone are owned here
/// (`add`), started while one of their providers is actually visible in the
/// menu-bar limit summary and stopped when none is. Merely connecting an
/// account does not create another two-second poller.
///
/// Keyed by provider id throughout, so each provider's state is its own: there
/// is no single "something is working" flag to set.
@MainActor
final class ProviderActivityBoard: ObservableObject {
    /// Providers consumed by the menu-bar summary only. A provider missing
    /// here is `unknown` even if its account is connected elsewhere.
    @Published private(set) var states: [String: ProviderActivityState] = [:]

    /// What each source said last, keyed by source.
    private var reports: [String: [String: ProviderActivityState]] = [:]
    private var consumed: Set<String> = []
    private var sources: [String: any ProviderActivitySource] = [:]
    private var subscriptions: [String: AnyCancellable] = [:]

    func state(for providerID: String) -> ProviderActivityState {
        states[providerID] ?? .unknown
    }

    /// Replaces everything `source` said before. An empty report withdraws it.
    func report(_ states: [String: ProviderActivityState], from source: String) {
        guard (reports[source] ?? [:]) != states else { return }
        reports[source] = states.isEmpty ? nil : states
        publish()
    }

    /// Takes ownership of a source; it runs once one of its providers is
    /// consumed by the status item.
    func add(_ source: any ProviderActivitySource, as key: String) {
        sources[key] = source
        reconcile()
    }

    /// The provider marks actually rendered by the status item. Owned sources
    /// follow this explicit consumer gate, and reports outside it stay cached
    /// but unpublished until there is a consumer.
    func setConsumed(_ providerIDs: Set<String>) {
        guard providerIDs != consumed else { return }
        consumed = providerIDs
        reconcile()
        publish()
    }

    func stop() {
        for key in Array(subscriptions.keys) { halt(key) }
        reports = [:]
        publish()
    }

    /// Everything reported, merged per provider and limited to consumers.
    static func merged(_ reports: [String: [String: ProviderActivityState]],
                       consumed: Set<String>) -> [String: ProviderActivityState] {
        var merged: [String: ProviderActivityState] = [:]
        for states in reports.values {
            for (id, state) in states where consumed.contains(id) {
                merged[id] = ProviderActivityState.merged([merged[id] ?? .unknown, state])
            }
        }
        return merged
    }

    private func publish() {
        let next = Self.merged(reports, consumed: consumed)
        if next != states { states = next }
    }

    private func reconcile() {
        for (key, source) in sources {
            let wanted = !source.providerIDs.isDisjoint(with: consumed)
            if wanted, subscriptions[key] == nil {
                subscriptions[key] = source.statesPublisher
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] states in
                        // A stopped source that publishes once more is not
                        // allowed back onto the board.
                        guard let self, self.subscriptions[key] != nil else { return }
                        self.report(states, from: key)
                    }
                source.start()
            } else if !wanted, subscriptions[key] != nil {
                halt(key)
            }
        }
    }

    private func halt(_ key: String) {
        subscriptions.removeValue(forKey: key)?.cancel()
        sources[key]?.stop()
        report([:], from: key)
    }
}
