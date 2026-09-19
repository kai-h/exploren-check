import SwiftUI

struct SettingsView: View {
    @Bindable var store: ChargerStore

    var body: some View {
        Form {
            Section {
                Stepper(value: $store.pollSeconds,
                        in: Preferences.minimumPollSeconds...Preferences.maximumPollSeconds,
                        step: 30) {
                    LabeledContent("Check every", value: interval)
                }
                Text("""
                     Only a backstop. Changes normally arrive over the live \
                     connection as they happen, so this is what catches a \
                     connection that has quietly died.
                     """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Updates")
            }

            Section {
                Stepper(value: $store.nearlyFreePercent, in: 50...100, step: 5) {
                    LabeledContent("Warn at", value: "\(store.nearlyFreePercent)% battery")
                }
                Text("""
                     An occupied charger counts as nearly free above this, and \
                     always when it is finishing or paused by the car. Battery \
                     level depends on the vehicle reporting it, which many \
                     slower chargers never do.
                     """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Early warning")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Seconds read oddly past a minute or two, so anything that divides
    /// evenly is shown in minutes.
    private var interval: String {
        let seconds = store.pollSeconds
        if seconds % 60 == 0 {
            let minutes = seconds / 60
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
        return "\(seconds) seconds"
    }
}
