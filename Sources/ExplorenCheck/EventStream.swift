import Foundation
import Observation

/// Live charger status over the platform's Laravel Echo Server.
///
/// `exploren.locations` is a public channel: subscribing with empty auth
/// headers is accepted without a token, exactly as the iOS app does before
/// anyone logs in. Events cover the whole tenant, so they are filtered down to
/// the watched locations here.
///
/// The transport is Engine.IO v3 over a websocket, connected directly rather
/// than via the usual polling handshake and upgrade, which the server allows.
/// Frames are `<engine><socketio>` prefixed: `0` open, `40` connected,
/// `42[...]` an event, `2`/`3` ping and pong.
@MainActor
@Observable
final class EventStream {

    enum Status: Equatable {
        case off
        case connecting
        case live
        case retrying(String)
    }

    private(set) var status: Status = .off

    private static let url = URL(
        string: "wss://echo.au.charge.ampeco.tech/socket.io/?EIO=3&transport=websocket")!
    private static let subscribeFrame =
        #"42["subscribe",{"channel":"exploren.locations","auth":{"headers":{}}}]"#

    /// Several events usually arrive together for one change, so they are
    /// coalesced before the refresh is triggered.
    private static let debounce = Duration.milliseconds(800)

    /// How long without a single frame counts as a dead connection. The
    /// server pongs each ping, so two intervals of silence is generous.
    private static func silenceLimit(_ pingInterval: Duration) -> TimeInterval {
        Double(pingInterval.components.seconds) * 2 + 10
    }

    private var watched: Set<Int> = []
    private var loop: Task<Void, Never>?
    private var pendingRefresh: Task<Void, Never>?
    private var lastFrame = Date()
    private var socket: URLSessionWebSocketTask?
    /// Set when something external, such as waking from sleep, wants the
    /// connection rebuilt without waiting out the backoff.
    private var forceReconnect = false
    private let onChange: @MainActor (Change) -> Void

    init(onChange: @escaping @MainActor (Change) -> Void) {
        self.onChange = onChange
    }

    func start(watching locations: Set<Int>) {
        watched = locations
        guard loop == nil else { return }
        loop = Task { [weak self] in await self?.run() }
    }

    /// Cheap: the connection is shared across all locations, so a changed
    /// watchlist only changes the filter.
    func update(watching locations: Set<Int>) {
        watched = locations
    }

    func stop() {
        loop?.cancel()
        loop = nil
        pendingRefresh?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        status = .off
    }

    /// Drops the current connection and rebuilds it immediately, skipping any
    /// accumulated backoff. Used on wake, where the old socket is usually a
    /// corpse that hasn't noticed yet.
    func reconnectNow() {
        guard loop != nil else { return }
        forceReconnect = true
        socket?.cancel(with: .abnormalClosure, reason: nil)
    }

    private func run() async {
        var backoff = 1.0
        while !Task.isCancelled {
            status = .connecting
            do {
                try await listen()
                backoff = 1.0
            } catch {
                guard !Task.isCancelled else { break }
                status = .retrying(error.localizedDescription)
            }
            guard !Task.isCancelled else { break }
            if forceReconnect {
                forceReconnect = false
                backoff = 1.0
                continue
            }
            try? await Task.sleep(for: .seconds(backoff))
            backoff = min(backoff * 2, 60)
        }
        status = .off
    }

    /// Returns when the connection closes, throws if it fails, and in either
    /// case the caller reconnects.
    private func listen() async throws {
        let socket = URLSession.shared.webSocketTask(with: Self.url)
        self.socket = socket
        lastFrame = Date()
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }

        var heartbeat: Task<Void, Never>?
        var watchdog: Task<Void, Never>?
        defer { heartbeat?.cancel(); watchdog?.cancel() }

        while true {
            let text = try await socket.receive().text
            lastFrame = Date()
            guard let text, let first = text.first else { continue }

            switch first {
            case "0":
                // Open packet. Engine.IO v3 expects the client to ping.
                let interval = Self.pingInterval(from: text)
                heartbeat?.cancel()
                heartbeat = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: interval)
                        guard !Task.isCancelled else { return }
                        do {
                            try await socket.send(.string("2"))
                        } catch {
                            // Swallowing this is how a dead connection used
                            // to masquerade as a live one. Tearing down the
                            // socket makes the pending receive() throw, which
                            // reconnects.
                            socket.cancel(with: .abnormalClosure, reason: nil)
                            return
                        }
                    }
                }

                // The server pongs every ping, so prolonged silence means the
                // connection is gone even though nothing has reported an
                // error. This is the state a laptop wakes up in.
                watchdog?.cancel()
                watchdog = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(10))
                        guard !Task.isCancelled, let self else { return }
                        if Date().timeIntervalSince(lastFrame) > Self.silenceLimit(interval) {
                            socket.cancel(with: .abnormalClosure, reason: nil)
                            return
                        }
                    }
                }
            case "4" where text == "40":
                try await socket.send(.string(Self.subscribeFrame))
                status = .live
            case "4":
                if let event = Self.parse(text) { handle(event) }
            default:
                break  // pong and anything else we don't need
            }
        }
    }

    // MARK: - Frame handling

    /// What an event is worth acting on.
    enum Change: Equatable {
        /// Something about availability moved: re-read status from the API.
        case availability
        /// A connected vehicle's battery level, applied straight to the
        /// displayed charger without a request.
        case stateOfCharge(evseId: String, percent: Int)
    }

    struct Event: Equatable {
        let name: String
        let locationId: Int?
        let evseId: Int?
        let socPercent: Int?

        /// State-of-charge updates are the bulk of the traffic and say nothing
        /// about whether a charger is free. Everything else is treated as
        /// worth a refresh, so an event type we haven't seen still gets
        /// noticed rather than silently ignored.
        var affectsAvailability: Bool {
            !name.hasSuffix("EVSEChargingPercentageChanged")
        }
    }

    /// `42["App\Events\X","exploren.locations",{...}]` -> Event
    static func parse(_ frame: String) -> Event? {
        guard frame.hasPrefix("42") else { return nil }
        guard let data = String(frame.dropFirst(2)).data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
              array.count >= 3,
              let name = array[0] as? String
        else { return nil }

        let payload = array[2] as? [String: Any]
        return Event(
            name: name,
            locationId: payload?["location_id"] as? Int,
            evseId: payload?["evse_id"] as? Int,
            socPercent: payload?["soc_percent"] as? Int
        )
    }

    /// Milliseconds from the open packet, `0{"sid":…,"pingInterval":25000,…}`.
    /// The server drops clients that stop pinging.
    static func pingInterval(from openFrame: String) -> Duration {
        guard openFrame.hasPrefix("0"),
              let data = String(openFrame.dropFirst()).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ms = object["pingInterval"] as? Int
        else { return .seconds(25) }
        return .milliseconds(ms)
    }

    fileprivate func handle(_ event: Event) {
        guard let locationId = event.locationId, watched.contains(locationId) else { return }

        // Battery level needs no round trip, so it is applied immediately.
        if let percent = event.socPercent, let evseId = event.evseId {
            onChange(.stateOfCharge(evseId: String(evseId), percent: percent))
            return
        }

        guard event.affectsAvailability else { return }
        pendingRefresh?.cancel()
        pendingRefresh = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled, let self else { return }
            self.onChange(.availability)
        }
    }
}

private extension URLSessionWebSocketTask.Message {
    var text: String? {
        switch self {
        case .string(let string): string
        case .data(let data): String(data: data, encoding: .utf8)
        @unknown default: nil
        }
    }
}
