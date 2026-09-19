import Foundation

// Wire types for POST /api/v1/app/locations.
//
// Note the three different number spaces in this API, only one of which a
// driver can actually see:
//   Location.id      2151  — internal, never printed anywhere
//   EVSE.id          8139  — internal, used in other API paths
//   EVSE.identifier  6451  — the number on the charger, and in its QR URL
// We key the watchlist on identifier for that reason.

struct LocationsResponse: Decodable {
    let locations: [Location]
    let tariffs: [Tariff]?
    let currencies: [Currency]?
}

struct Currency: Decodable {
    let code: String
    let sign: String?
}

/// Ids are strings, and not always numeric: a merged duration-and-energy
/// tariff comes back with an id like "732-1507".
struct Tariff: Decodable {
    let id: String
    let currencyCode: String?
    let priceForEnergy: Double?
    let priceForDuration: Double?
    let priceForIdle: Double?
    let pricingPeriodInMinutes: Int?
    let idleFeeGracePeriodMinutes: Int?
    let arePricesTaxInclusive: Bool?
    let pricePeriods: [PricePeriod]?

    /// The per-kWh price lives in one of two places depending on the tariff:
    /// flat in `priceForEnergy`, or inside the time-of-day `pricePeriods`.
    var energyPerKwh: Double? {
        if let priceForEnergy, priceForEnergy > 0 { return priceForEnergy }
        return pricePeriods?.compactMap(\.energyPerKwh).first { $0 > 0 }
    }
}

struct PricePeriod: Decodable {
    let energyPerKwh: Double?
}

struct Location: Decodable {
    let id: Int
    let name: String?
    let address: String?
    let zones: [Zone]
}

struct PinsResponse: Decodable {
    let pins: [Pin]
}

struct Pin: Decodable {
    /// A pin can stand for several locations once the map clusters them.
    let underlyingLocationIds: [Int]
}

struct Zone: Decodable {
    let evses: [EVSE]
}

struct EVSE: Decodable {
    let id: String
    let identifier: String?
    let status: String?
    let maxPower: Double?
    /// Battery level of the connected vehicle, when it reports one. Often
    /// null: it depends on the car and the charger talking a protocol that
    /// carries it.
    let socPercent: Int?
    /// No tariff attached means the charger is free to use. Tariffs vary
    /// between chargers at one location, so this is per EVSE.
    let tariffId: String?
}

/// What a charger costs, resolved from its tariff. `nil` pricing means free.
struct Pricing: Equatable, Sendable {
    let sign: String
    let energyPerKwh: Double?
    let perMinute: Double?
    let idlePerMinute: Double?
    let idleGraceMinutes: Int?
    let taxInclusive: Bool

    /// Short enough for a table row.
    var label: String {
        if let energyPerKwh { return "\(sign)\(trim(energyPerKwh))/kWh" }
        if let perMinute { return "\(sign)\(trim(perMinute))/min" }
        return "Paid"
    }

    /// The idle fee is the part that catches people out, so it goes in a
    /// tooltip rather than being dropped.
    var detail: String? {
        guard let idlePerMinute, idlePerMinute > 0 else { return nil }
        let grace = idleGraceMinutes.map { " after \($0) min" } ?? ""
        return "Idle fee \(sign)\(trim(idlePerMinute))/min\(grace)"
            + (taxInclusive ? ", tax inclusive" : "")
    }

    private func trim(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f", value)
                                 : String(format: "%.2f", value)
    }

    init?(tariff: Tariff?, sign: String) {
        guard let tariff else { return nil }
        self.sign = sign
        self.energyPerKwh = tariff.energyPerKwh
        self.perMinute = (tariff.priceForDuration ?? 0) > 0 ? tariff.priceForDuration : nil
        self.idlePerMinute = (tariff.priceForIdle ?? 0) > 0 ? tariff.priceForIdle : nil
        self.idleGraceMinutes = tariff.idleFeeGracePeriodMinutes
        self.taxInclusive = tariff.arePricesTaxInclusive ?? false
    }
}

/// A single charger, flattened for display.
struct ChargerStatus: Identifiable, Equatable, Sendable {
    let evseId: String
    let identifier: String
    let locationId: Int
    let locationName: String
    let status: String
    let maxPowerW: Double?
    /// Updated in place by the event stream between polls.
    var socPercent: Int?
    /// nil means free to use.
    let pricing: Pricing?

    /// When this charger was seen to change into its current status. Nil
    /// until we actually witness a change, since finding it already charging
    /// on the first poll says nothing about how long it has been that way.
    var since: Date?

    var id: String { evseId }

    var isAvailable: Bool { status == Self.available }

    var statusLabel: String { ExplorenCheck.statusLabel(status) }

    var powerLabel: String? { ExplorenCheck.powerLabel(watts: maxPowerW) }

    static let available = "available"
}

/// "22 kW", or nil when the API didn't say.
func powerLabel(watts: Double?) -> String? {
    guard let watts, watts > 0 else { return nil }
    let kw = watts / 1000
    return kw == kw.rounded() ? "\(Int(kw)) kW" : String(format: "%.1f kW", kw)
}

// MARK: - Discovery

/// A location as offered in the picker, before anything is watched.
struct DiscoveredLocation: Identifiable, Sendable {
    let id: Int
    let name: String
    let address: String?
    let chargers: [DiscoveredCharger]
}

struct DiscoveredCharger: Identifiable, Sendable {
    let evseId: String
    /// The number printed on the unit. What the user actually picks by.
    let identifier: String
    let status: String
    let maxPowerW: Double?
    let pricing: Pricing?

    var id: String { evseId }
    var powerLabel: String? { ExplorenCheck.powerLabel(watts: maxPowerW) }
}

/// The raw OCPP statuses don't capitalise sensibly, and the two suspended
/// states are worth telling apart: a car that has stopped drawing power is
/// usually nearly done, whereas the charger curtailing says nothing about
/// when the bay will free up.
func statusLabel(_ status: String) -> String {
    switch status {
    case "suspendedev": "Paused by car"
    case "suspendedevse": "Paused by charger"
    case "out of order": "Out of order"
    default: status.capitalized
    }
}

/// Elapsed time as `H:MM`. Hours keep counting past 24 rather than rolling
/// over, so a charger occupied since yesterday reads 27:15 and not 3:15.
func clockDuration(since date: Date, now: Date = Date()) -> String {
    let minutes = max(0, Int(now.timeIntervalSince(date)) / 60)
    return String(format: "%d:%02d", minutes / 60, minutes % 60)
}
