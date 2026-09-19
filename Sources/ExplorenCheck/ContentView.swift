import SwiftUI

struct ContentView: View {
    @Bindable var store: ChargerStore
    @Binding var picker: PickerModel?
    @State private var collapsed: Set<Int> = Set(
        UserDefaults.standard.array(forKey: ContentView.collapsedKey) as? [Int] ?? [])
    /// Re-read once a minute so the elapsed figures stay true. Without this
    /// they are computed once when a row first draws and then sit frozen,
    /// which with the live stream carrying most updates means a charger that
    /// just changed reads 0:00 indefinitely.
    ///
    /// Not a running clock: the value is still now minus when the change was
    /// seen. A minute is simply the coarsest refresh that can keep an H:MM
    /// display honest.
    @State private var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if store.preferences.watch.isEmpty {
                // First run, and whenever everything has been unticked. Sends
                // people to the picker rather than leaving an empty window
                // that looks like a failure to load.
                ContentUnavailableView {
                    Label("No chargers yet", systemImage: "bolt.horizontal")
                } description: {
                    Text("Pick the chargers you want to watch, by the number printed on them.")
                } actions: {
                    Button("Choose Chargers…") {
                        picker = PickerModel(watching: store.preferences.watch)
                    }
                }
                .frame(maxHeight: .infinity)
            } else if store.chargers.isEmpty && store.errorMessage == nil {
                ContentUnavailableView(
                    "Loading",
                    systemImage: "bolt.horizontal",
                    description: Text("Fetching charger status…")
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(groupedByLocation) { group in
                        DisclosureGroup(isExpanded: expansion(group.id)) {
                            ForEach(group.chargers) { ChargerRow(charger: $0, now: now) }
                        } label: {
                            HStack {
                                Text(group.name)
                                    .font(.subheadline)
                                Spacer()
                                Text(group.summary)
                                    .font(.caption)
                                    .foregroundStyle(group.freeCount > 0 ? .green : .secondary)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }

            footer
        }
        .frame(minWidth: 320, minHeight: 240)
        .task { store.start() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                now = Date()
            }
        }
        .sheet(item: $picker) { model in
            ChargerPicker(model: model) { store.updateWatchList($0) }
        }
    }

    struct LocationGroup: Identifiable {
        let id: Int
        let name: String
        let chargers: [ChargerStatus]

        var freeCount: Int { chargers.filter(\.isAvailable).count }
        /// "1/2 free", the whole point of collapsing a location away.
        var summary: String { "\(freeCount)/\(chargers.count) free" }
    }

    /// Locations keep the watchlist's order rather than being sorted.
    private var groupedByLocation: [LocationGroup] {
        var order: [Int] = []
        var byLocation: [Int: [ChargerStatus]] = [:]
        for charger in store.chargers {
            if byLocation[charger.locationId] == nil { order.append(charger.locationId) }
            byLocation[charger.locationId, default: []].append(charger)
        }
        return order.map {
            LocationGroup(
                id: $0,
                name: byLocation[$0]?.first?.locationName ?? "Location \($0)",
                chargers: byLocation[$0] ?? []
            )
        }
    }

    /// Collapsed locations persist between launches, keyed by location id so
    /// two sites sharing a name don't collapse together.
    private static let collapsedKey = "collapsedLocations"

    private func expansion(_ id: Int) -> Binding<Bool> {
        Binding(
            get: { !collapsed.contains(id) },
            set: { expanded in
                if expanded { collapsed.remove(id) } else { collapsed.insert(id) }
                UserDefaults.standard.set(Array(collapsed), forKey: Self.collapsedKey)
            }
        )
    }

    private var header: some View {
        HStack {
            Spacer()
            Button {
                picker = PickerModel(watching: store.preferences.watch)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Choose chargers to watch")

            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(store.isRefreshing)
            .help("Refresh now")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// A dead event stream is invisible otherwise: status would silently go
    /// back to arriving only on the slower poll.
    @ViewBuilder
    private var streamBadge: some View {
        switch store.streamStatus {
        case .live:
            Label("Live", systemImage: "bolt.fill")
                .foregroundStyle(.green)
        case .connecting:
            Label("Connecting", systemImage: "bolt")
        case .retrying:
            Label("Polling only", systemImage: "bolt.slash")
                .help("Live updates unavailable, reconnecting.")
        case .off:
            EmptyView()
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if let issue = store.notificationIssue {
                HStack(spacing: 6) {
                    Label(issue, systemImage: "bell.slash")
                        .foregroundStyle(.secondary)
                    Button("Open Settings") { Notifier.openNotificationSettings() }
                        .buttonStyle(.link)
                }
            }
            HStack(spacing: 6) {
                if let updated = store.lastUpdated {
                    Text("Updated \(updated.formatted(date: .omitted, time: .standard))")
                }
                Spacer()
                streamBadge
            }
            .foregroundStyle(.secondary)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

struct ChargerRow: View {
    let charger: ChargerStatus
    /// Passed in rather than read from the clock here, so every row agrees on
    /// what "now" is and the whole list updates together.
    let now: Date

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(colour)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 1) {
                Text(charger.identifier)
                    .font(.system(.body, design: .monospaced))
                priceLabel
            }

            Spacer()

            // Only meaningful while a car is plugged in, and only when the
            // vehicle reports it at all.
            if let soc = charger.socPercent {
                Label("\(soc)%", systemImage: "battery.50")
                    .foregroundStyle(.secondary)
                    .help("Connected vehicle's battery level")
            }

            if let power = charger.powerLabel {
                Text(power).foregroundStyle(.secondary)
            }

            VStack(alignment: .trailing, spacing: 1) {
                Text(charger.statusLabel)
                    .foregroundStyle(colour)
                // Nothing below a minute: "0:00" is noise, and it is what a
                // freshly observed change reads as for its first minute.
                if let since = charger.since, now.timeIntervalSince(since) >= 60 {
                    Text(clockDuration(since: since, now: now))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(minWidth: 84, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    /// No tariff on an EVSE means it costs nothing to use.
    @ViewBuilder
    private var priceLabel: some View {
        if let pricing = charger.pricing {
            Text(pricing.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(pricing.detail ?? pricing.label)
        } else {
            Text("Free")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }

    private var colour: Color {
        switch charger.status {
        case "available": .green
        case "charging", "preparing", "finishing", "reserved",
             "suspendedev", "suspendedevse": .orange
        case "faulted", "out of order", "unavailable": .red
        default: .secondary
        }
    }
}
