import Foundation

/// Read-only client for the Exploren/Ampeco app API.
///
/// Charger status is public: the endpoint needs no token, and the only header
/// it insists on is Content-Type. We deliberately send our own User-Agent
/// rather than impersonating the iOS app, and touch no write endpoints.
struct ExplorenAPI: Sendable {

    enum Failure: LocalizedError {
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .http(let code): "Server returned HTTP \(code)"
            }
        }
    }

    private static let endpoint = URL(
        string: "https://exploren.au.charge.ampeco.tech/api/v1/app/locations?operatorCountry=AU")!

    private static let userAgent = "ExplorenCheck/0.1 (macOS; +status polling)"

    func fetch(watch: [WatchEntry]) async throws -> [ChargerStatus] {
        guard !watch.isEmpty else { return [] }

        // The API takes a map of location id -> "" (an etag slot the app uses
        // for caching; sending empty always returns fresh data).
        let body = ["locations": Dictionary(
            watch.map { (String($0.locationId), "") }, uniquingKeysWith: { a, _ in a })]

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Failure.http(http.statusCode)
        }

        let decoded = try JSONDecoder().decode(LocationsResponse.self, from: data)
        return Self.flatten(decoded, watch: watch)
    }

    // MARK: - Discovery

    /// The server caps `pins` at this many, whatever `limit` asks for.
    static let pinLimit = 80

    struct Discovery: Sendable {
        var locations: [DiscoveredLocation]
        /// True when the pin cap was hit, so there may be more out of view.
        var truncated: Bool
    }

    func discover(latitude: Double, longitude: Double, radiusKm: Double) async throws -> Discovery {
        let dLat = radiusKm / 111.0
        let dLon = radiusKm / (111.0 * cos(latitude * .pi / 180))

        var components = URLComponents(
            string: "https://exploren.au.charge.ampeco.tech/api/v1/app/pins")!
        components.queryItems = [
            .init(name: "minLatitude", value: String(latitude - dLat)),
            .init(name: "maxLatitude", value: String(latitude + dLat)),
            .init(name: "minLongitude", value: String(longitude - dLon)),
            .init(name: "maxLongitude", value: String(longitude + dLon)),
            .init(name: "limit", value: String(Self.pinLimit)),
            .init(name: "withCurrentTypes", value: "true"),
            .init(name: "includeAvailability", value: "true"),
            .init(name: "operatorCountry", value: "AU"),
        ]

        var request = URLRequest(url: components.url!)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Failure.http(http.statusCode)
        }

        let pins = try JSONDecoder().decode(PinsResponse.self, from: data).pins
        let ids = Array(Set(pins.flatMap(\.underlyingLocationIds))).sorted()
        guard !ids.isEmpty else { return Discovery(locations: [], truncated: false) }

        return Discovery(
            locations: try await detail(ids: ids),
            truncated: pins.count >= Self.pinLimit
        )
    }

    /// Full detail for arbitrary location ids, sorted by name for the picker.
    private func detail(ids: [Int]) async throws -> [DiscoveredLocation] {
        let body = ["locations": Dictionary(
            ids.map { (String($0), "") }, uniquingKeysWith: { a, _ in a })]

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Failure.http(http.statusCode)
        }

        let decoded = try JSONDecoder().decode(LocationsResponse.self, from: data)
        let pricing = Self.pricingLookup(decoded)

        return decoded.locations
            .map { location in
                DiscoveredLocation(
                    id: location.id,
                    name: location.name ?? "Location \(location.id)",
                    address: location.address,
                    chargers: location.zones.flatMap(\.evses)
                        .map {
                            DiscoveredCharger(
                                evseId: $0.id,
                                identifier: $0.identifier ?? $0.id,
                                status: ($0.status ?? "unknown").lowercased(),
                                maxPowerW: $0.maxPower,
                                pricing: pricing($0.tariffId)
                            )
                        }
                        .sorted { $0.identifier < $1.identifier }
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Resolves an EVSE's tariff id to what it costs. A charger with no
    /// tariff is free, which is how the absence is meant to be read.
    static func pricingLookup(_ response: LocationsResponse) -> (String?) -> Pricing? {
        let tariffs = Dictionary(
            (response.tariffs ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let signs = Dictionary(
            (response.currencies ?? []).map { ($0.code, $0.sign ?? "$") },
            uniquingKeysWith: { a, _ in a })

        return { tariffId in
            guard let tariffId, let tariff = tariffs[tariffId] else { return nil }
            let sign = tariff.currencyCode.flatMap { signs[$0] } ?? "$"
            return Pricing(tariff: tariff, sign: sign)
        }
    }

    /// Picks out the watched EVSEs, in the order the watchlist names them.
    static func flatten(_ response: LocationsResponse, watch: [WatchEntry]) -> [ChargerStatus] {
        let wanted = Dictionary(
            watch.map { ($0.locationId, $0.identifiers) }, uniquingKeysWith: { a, _ in a })
        let pricing = pricingLookup(response)

        var result: [ChargerStatus] = []
        for location in response.locations {
            guard let identifiers = wanted[location.id] else { continue }
            let all = location.zones.flatMap(\.evses)
            let matching = identifiers.isEmpty
                ? all.sorted { ($0.identifier ?? "") < ($1.identifier ?? "") }
                : identifiers.compactMap { wantedID in all.first { $0.identifier == wantedID } }

            result += matching.map {
                ChargerStatus(
                    evseId: $0.id,
                    identifier: $0.identifier ?? $0.id,
                    locationId: location.id,
                    locationName: location.name ?? "Location \(location.id)",
                    status: ($0.status ?? "unknown").lowercased(),
                    maxPowerW: $0.maxPower,
                    socPercent: $0.socPercent,
                    pricing: pricing($0.tariffId)
                )
            }
        }
        return result
    }
}
