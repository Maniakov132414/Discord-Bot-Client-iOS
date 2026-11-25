import SwiftUI
import UIKit
import UserNotifications

@main
struct DiscordBotClientApp: App {
    @StateObject private var vault = BotVaultStore.shared
    @StateObject private var gateway = DiscordGatewayService.shared
    @Environment(\.scenePhase) private var scenePhase

    private let notificationDelegate = NotificationCenterDelegate()

    init() {
        UNUserNotificationCenter.current().delegate = notificationDelegate
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(vault.preferredColorScheme)
                .tint(vault.accentColor)
                .environmentObject(vault)
                .environmentObject(gateway)
                .onChange(of: scenePhase) { newPhase in
                    if newPhase == .active {
                        Task { await gateway.reconnectIfNeeded(vault: vault) }
                    }
                }
        }
    }
}

private final class NotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let channelId = userInfo["channel_id"] as? String {
            let guildId = userInfo["guild_id"] as? String
            Task { @MainActor in
                DiscordGatewayService.shared.jumpToChannel(channelId: channelId, guildId: guildId)
            }
        }
        completionHandler()
    }
}
