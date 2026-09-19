import AppKit
import Foundation
import UserNotifications

/// Local notifications for the occupied -> available edge.
///
/// Requires a signed app bundle; see build.sh. If authorisation is refused or
/// unavailable the app keeps polling and just shows status in the window, so
/// the failure is reported rather than swallowed.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private(set) var authorisationError: String?
    private var authorised = false
    private var decided = false

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Without this, macOS silently files notifications raised while our own
    /// window is frontmost straight into Notification Centre, showing no
    /// banner. The window being open is exactly when you're watching for a
    /// charger to free up, so present them regardless.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    /// Asks once if the user hasn't decided yet. The prompt blocks until they
    /// answer, so state is read separately rather than inferred from the
    /// request's return value.
    func prepare() async {
        await syncState()
        guard !decided else { return }
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
        await syncState()
    }

    /// Cheap and non-blocking. Called on every poll so the footer stops
    /// nagging the moment the user answers the prompt.
    func syncState() async {
        let status = await UNUserNotificationCenter.current().notificationSettings()
            .authorizationStatus
        decided = status != .notDetermined

        switch status {
        case .authorized, .provisional, .ephemeral:
            authorised = true
            authorisationError = nil
        case .denied:
            authorised = false
            authorisationError = "Notifications are turned off for this app."
        case .notDetermined:
            authorised = false
            authorisationError = "Waiting for notification permission."
        @unknown default:
            authorised = false
            authorisationError = "Notification permission is in an unknown state."
        }
    }

    func chargerBecameAvailable(_ charger: ChargerStatus) {
        guard authorised else { return }
        post(
            id: "available-\(charger.evseId)",
            title: "Charger \(charger.identifier) is free",
            body: charger.powerLabel.map { "\(charger.locationName) · \($0)" }
                ?? charger.locationName
        )
    }

    /// A heads-up while the bay is still occupied, which is the part that
    /// actually buys you time to get there.
    func chargerNearlyFree(_ charger: ChargerStatus, detail: String) {
        guard authorised else { return }
        post(
            id: "nearly-\(charger.evseId)",
            title: "Charger \(charger.identifier) is nearly free",
            body: "\(charger.locationName) · \(detail)"
        )
    }

    /// Delivery can't be verified by waiting for a charger to free up, so it
    /// gets a menu item.
    func sendTest() {
        post(id: "test", title: "Charger 0000 is free", body: "Test notification")
    }

    private func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: "\(id)-\(Date().timeIntervalSince1970)",
                content: content,
                trigger: nil
            )
        )
    }

    /// The permission prompt only ever appears once, so a refused app needs
    /// sending to System Settings.
    static func openNotificationSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
