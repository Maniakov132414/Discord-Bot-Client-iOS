import SwiftUI
import UIKit

@main
struct DiscordBotClientApp: App {
    @StateObject private var vault = BotVaultStore.shared
    @StateObject private var gateway = DiscordGatewayService.shared
    @Environment(\.scenePhase) private var scenePhase

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
