import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class ChargerStore {
    private(set) var chargers: [ChargerStatus] = []
    private(set) var lastUpdated: Date?
    private(set) var errorMessage: String?
    private(set) var isRefreshing = false

    var notificationIssue: String? { notifier.authorisationError }

    private(set) var preferences: Preferences

    /// How often to poll while the event stream is live. The stream carries
    /// the changes, so this only guards against a silently dead connection.
    private static let backstopSeconds = 300

    var streamStatus: EventStream.Status { stream?.status ?? .off }

    private let api = ExplorenAPI()
    private let notifier = Notifier()
    private var stream: EventStream?
    private var previousStatus: [String: String] = [:]
    /// evseId -> when we saw it change into its current status. Only holds
    /// entries for changes witnessed while the app has been running.
    private var stateSince: [String: Date] = [:]
    /// Chargers already warned about in their current occupancy.
    private var warnedNearlyFree: Set<String> = []
    private var pollTask: Task<Void, Never>?
    private var wakeObserver: (any NSObjectProtocol)?

    private var watchedLocationIds: Set<Int> {
        Set(preferences.watch.map(\.locationId))
    }

    init(preferences: Preferences = .load()) {
        self.preferences = preferences
    }

    func start() {
        guard pollTask == nil else { return }
        // Authorisation is requested alongside polling, not before it: the
        // permission dialog blocks until the user answers, and status should
        // appear regardless of whether they ever do.
        Task { [weak self] in await self?.notifier.prepare() }

        let stream = EventStream { [weak self] change in
            guard let self else { return }
            switch change {
            case .availability:
                Task { await self.refresh() }
            case .stateOfCharge(let evseId, let percent):
                self.applyStateOfCharge(evseId: evseId, percent: percent)
            }
        }
        self.stream = stream
        stream.start(watching: watchedLocationIds)

        // After sleep the websocket is usually a corpse that hasn't noticed,
        // and the displayed status is however old the lid-close was.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.stream?.reconnectNow()
                Task { await self.refresh() }
            }
        }

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                guard let self else { return }
                let base = preferences.pollInterval
                let seconds = streamStatus == .live
                    ? max(base, Self.backstopSeconds)
                    : base
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        stream?.stop()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
    }

    func sendTestNotification() { notifier.sendTest() }

    /// Settings, bindable straight from the window. Each write persists, and
    /// the poll loop reads the interval fresh each time round, so a change
    /// takes effect on the next cycle without restarting anything.
    var pollSeconds: Int {
        get { preferences.pollInterval }
        set {
            preferences.pollSeconds = newValue
            persistPreferences()
        }
    }

    var nearlyFreePercent: Int {
        get { preferences.nearlyFreeThreshold }
        set {
            preferences.nearlyFreePercent = newValue
            // Lowering the threshold should be able to warn about a charger
            // that is already past the new figure, so the record of what has
            // been announced is cleared.
            warnedNearlyFree = []
            persistPreferences()
        }
    }

    private func persistPreferences() {
        do {
            try preferences.write()
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't save settings: \(error.localizedDescription)"
        }
    }

    /// Battery level arrives far more often than anything else, so it updates
    /// the row in place rather than costing a request.
    private func applyStateOfCharge(evseId: String, percent: Int) {
        guard let index = chargers.firstIndex(where: { $0.evseId == evseId }) else { return }
        chargers[index].socPercent = percent
        // A car crossing the threshold does so through this path, not through
        // a poll, so the check has to happen here too.
        evaluateNearlyFree(chargers[index])
    }

    /// Finishing and "paused by car" both mean the session is essentially
    /// over, and a high battery means it is close to it.
    private func isNearlyFree(_ charger: ChargerStatus) -> Bool {
        if charger.status == "finishing" || charger.status == "suspendedev" { return true }
        if let soc = charger.socPercent, soc >= preferences.nearlyFreeThreshold { return true }
        return false
    }

    /// Fires once per occupancy, and rearms when the charger stops looking
    /// nearly free, so a car sitting at 99% doesn't notify on every event.
    private func evaluateNearlyFree(_ charger: ChargerStatus, seeding: Bool = false) {
        guard !charger.isAvailable, isNearlyFree(charger) else {
            warnedNearlyFree.remove(charger.evseId)
            return
        }
        // Marked on the first poll but not announced, so a charger already
        // sitting at 99% when the app launches stays quiet, and only a
        // genuine move into "nearly free" notifies.
        let isNew = warnedNearlyFree.insert(charger.evseId).inserted
        guard isNew, !seeding else { return }

        let detail = charger.socPercent.map { "\($0)%" } ?? charger.statusLabel
        notifier.chargerNearlyFree(charger, detail: detail)
    }

    /// Replaces the watchlist, saves it, and starts again from a clean slate
    /// so a newly watched charger that is already free doesn't fire straight
    /// away.
    func updateWatchList(_ watch: [WatchEntry]) {
        preferences.watch = watch
        persistPreferences()

        stream?.update(watching: watchedLocationIds)
        previousStatus = [:]
        stateSince = [:]
        warnedNearlyFree = []
        chargers = []
        Task { await refresh() }
    }

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        await notifier.syncState()
        do {
            let fresh = try await api.fetch(watch: preferences.watch)
            chargers = ingest(fresh)
            lastUpdated = Date()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Single pass over a fresh reading: notifies on a genuine edge into
    /// available, and stamps how long each charger has held its status.
    ///
    /// Notifications fire only on an observed transition. The first poll
    /// seeds the baseline silently, so launching next to a free charger
    /// stays quiet.
    private func ingest(_ fresh: [ChargerStatus]) -> [ChargerStatus] {
        let seeding = previousStatus.isEmpty
        let now = Date()
        var stamped: [ChargerStatus] = []

        for var charger in fresh {
            let was = previousStatus[charger.evseId]

            // Only a witnessed change is stamped. Finding a charger already
            // in some state on the first poll tells us nothing about when it
            // got there, so it stays unstamped and shows no duration.
            if let was, was != charger.status {
                stateSince[charger.evseId] = now
            }
            if !seeding, charger.isAvailable, let was, was != ChargerStatus.available {
                notifier.chargerBecameAvailable(charger)
            }
            evaluateNearlyFree(charger, seeding: seeding)

            charger.since = stateSince[charger.evseId]
            stamped.append(charger)

            previousStatus[charger.evseId] = charger.status
        }
        return stamped
    }
}
