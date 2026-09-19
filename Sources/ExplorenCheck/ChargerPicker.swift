import CoreLocation
import Observation
import SwiftUI

@MainActor
@Observable
final class PickerModel: Identifiable {
    let id = UUID()
    var query = ""
    var radiusKm = 3.0
    private(set) var results: [DiscoveredLocation] = []
    private(set) var isSearching = false
    private(set) var message: String?
    private(set) var hasSearched = false

    /// A ticked charger, identified the way the watchlist stores it. Keying on
    /// this rather than on the search results means selections made in one
    /// search survive the next one.
    struct Watched: Hashable, Sendable {
        let locationId: Int
        let identifier: String
    }

    var selected: Set<Watched> = []

    /// Hand-written "watch everything here" entries, preserved untouched
    /// unless the picker is given an explicit selection for that location.
    private var wholeLocationEntries: [WatchEntry] = []

    private let api = ExplorenAPI()
    private let places = PlaceFinder()

    init(watching: [WatchEntry]) {
        for entry in watching {
            if entry.identifiers.isEmpty {
                wholeLocationEntries.append(entry)
            } else {
                for identifier in entry.identifiers {
                    selected.insert(Watched(locationId: entry.locationId, identifier: identifier))
                }
            }
        }
    }

    func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await run { try await self.places.coordinate(for: trimmed) }
    }

    func searchNearMe() async {
        await run { try await self.places.currentCoordinate() }
    }

    private func run(_ locate: @escaping () async throws -> CLLocationCoordinate2D) async {
        isSearching = true
        message = nil
        defer { isSearching = false; hasSearched = true }

        do {
            let centre = try await locate()
            let found = try await api.discover(
                latitude: centre.latitude,
                longitude: centre.longitude,
                radiusKm: radiusKm
            )
            results = found.locations
            if found.locations.isEmpty {
                message = "No chargers within \(Int(radiusKm)) km. Try a larger radius."
            } else if found.truncated {
                message = "Showing the first \(ExplorenAPI.pinLimit) pins — narrow the radius to be sure you've seen everything."
            }
        } catch {
            results = []
            message = error.localizedDescription
        }
    }

    /// Collapses the ticked chargers back into watchlist entries. Built from
    /// the selection alone, so chargers watched outside the current search are
    /// not quietly dropped.
    func watchList() -> [WatchEntry] {
        var identifiersByLocation: [Int: [String]] = [:]
        for watched in selected {
            identifiersByLocation[watched.locationId, default: []].append(watched.identifier)
        }

        let explicit = identifiersByLocation.map {
            WatchEntry(locationId: $0.key, identifiers: $0.value.sorted())
        }
        let untouched = wholeLocationEntries.filter {
            identifiersByLocation[$0.locationId] == nil
        }
        return (explicit + untouched).sorted { $0.locationId < $1.locationId }
    }

    var selectionCount: Int { selected.count + wholeLocationEntries.count }
}

struct ChargerPicker: View {
    @Bindable var model: PickerModel
    let onSave: ([WatchEntry]) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            results
            Divider()
            footer
        }
        .frame(width: 460, height: 520)
    }

    private var searchBar: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Suburb, address or place name", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.search() } }
                Button("Search") { Task { await model.search() } }
                    .disabled(model.query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                Button("Near Me") { Task { await model.searchNearMe() } }
                Spacer()
                Picker("Within", selection: $model.radiusKm) {
                    Text("3 km").tag(3.0)
                    Text("10 km").tag(10.0)
                    Text("25 km").tag(25.0)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var results: some View {
        if model.isSearching {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.results.isEmpty {
            ContentUnavailableView(
                model.hasSearched ? "Nothing found" : "Find chargers",
                systemImage: "magnifyingglass",
                description: Text(model.message
                    ?? "Search for a place, or use Near Me, then tick the chargers to watch.")
            )
            .frame(maxHeight: .infinity)
        } else {
            List {
                ForEach(model.results) { location in
                    Section {
                        ForEach(location.chargers) { charger in
                            row(charger, in: location)
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(location.name)
                            if let address = location.address {
                                Text(address)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func row(_ charger: DiscoveredCharger, in location: DiscoveredLocation) -> some View {
        let watched = PickerModel.Watched(
            locationId: location.id, identifier: charger.identifier)

        return Toggle(isOn: Binding(
            get: { model.selected.contains(watched) },
            set: { on in
                if on { model.selected.insert(watched) }
                else { model.selected.remove(watched) }
            }
        )) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(charger.identifier)
                        .font(.system(.body, design: .monospaced))
                    if let pricing = charger.pricing {
                        Text(pricing.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help(pricing.detail ?? pricing.label)
                    } else {
                        Text("Free").font(.caption).foregroundStyle(.green)
                    }
                }
                Spacer()
                if let power = charger.powerLabel {
                    Text(power).foregroundStyle(.secondary)
                }
                Text(statusLabel(charger.status))
                    .foregroundStyle(charger.status == ChargerStatus.available ? .green : .secondary)
                    .frame(minWidth: 76, alignment: .trailing)
            }
        }
        .toggleStyle(.checkbox)
    }

    private var footer: some View {
        HStack {
            if let message = model.message, !model.results.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Cancel") { dismiss() }
            Button("Watch \(model.selectionCount)") {
                onSave(model.watchList())
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.selectionCount == 0)
        }
        .padding(12)
    }
}
