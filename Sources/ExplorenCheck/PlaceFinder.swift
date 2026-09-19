import CoreLocation
import Foundation

/// Turns what the user typed, or where they are, into a coordinate.
///
/// Geocoding is done by macOS rather than the charging API, which has no
/// search endpoint of its own.
struct PlaceFinder: Sendable {

    enum Failure: LocalizedError {
        case noSuchPlace(String)
        case locationDenied
        case locationUnavailable

        var errorDescription: String? {
            switch self {
            case .noSuchPlace(let query):
                "Couldn't find anywhere called \"\(query)\"."
            case .locationDenied:
                "Location access was refused — enable it in System Settings, or search instead."
            case .locationUnavailable:
                "Couldn't determine where you are."
            }
        }
    }

    func coordinate(for query: String) async throws -> CLLocationCoordinate2D {
        let placemarks = try? await CLGeocoder().geocodeAddressString(query)
        guard let coordinate = placemarks?.first?.location?.coordinate else {
            throw Failure.noSuchPlace(query)
        }
        return coordinate
    }

    func currentCoordinate() async throws -> CLLocationCoordinate2D {
        for try await update in CLLocationUpdate.liveUpdates() {
            if let location = update.location { return location.coordinate }
            if update.authorizationDenied { throw Failure.locationDenied }
        }
        throw Failure.locationUnavailable
    }
}
