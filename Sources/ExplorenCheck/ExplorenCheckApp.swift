import ServiceManagement
import SwiftUI

/// Launch at login, via the modern SMAppService rather than a login item
/// helper bundle. Reads back the real state rather than storing our own, so
/// it stays right if the user changes it in System Settings.
@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns a message when macOS refuses, which it does for an unsigned or
    /// ad-hoc signed build in some locations.
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return "Couldn't change launch at login: \(error.localizedDescription)"
        }
    }
}

@main
struct ExplorenCheckApp: App {
    @State private var store = ChargerStore()
    // Held here rather than in ContentView so the menu bar can open the
    // picker too, not just the button in the window.
    @State private var picker: PickerModel?
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchAtLoginError: String?

    var body: some Scene {
        Window("Chargers", id: "chargers") {
            ContentView(store: store, picker: $picker)
        }
        .defaultSize(width: 360, height: 280)
        .commands {
            // Cmd-comma belongs to Settings, which the Settings scene below
            // takes automatically. Choosing chargers gets its own item and
            // shortcut, and is also a button in the window.
            CommandGroup(after: .appSettings) {
                Button("Choose Chargers…") {
                    picker = PickerModel(watching: store.preferences.watch)
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])

                Divider()

                Toggle("Open at Login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { wanted in
                        launchAtLoginError = LaunchAtLogin.set(wanted)
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
                ))

                if let launchAtLoginError {
                    Text(launchAtLoginError)
                }

                Divider()

                // The file still holds pollSeconds, which the picker doesn't
                // cover, so revealing it stays useful. Just not on Cmd-comma.
                Button("Reveal Watchlist File in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Preferences.fileURL])
                }

                Button("Send Test Notification") { store.sendTestNotification() }
            }
        }

        Settings {
            SettingsView(store: store)
        }
    }
}
