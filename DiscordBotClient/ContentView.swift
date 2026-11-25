import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var vault: BotVaultStore
    @EnvironmentObject private var gateway: DiscordGatewayService

    var body: some View {
        Group {
            if vault.activeBot != nil {
                MainTabShellView()
            } else {
                OnboardingLoginView()
            }
        }
        .task {
            if let active = vault.activeBot, gateway.connectionState == .disconnected {
                await gateway.connect(account: active, vault: vault)
            }
        }
    }
}
