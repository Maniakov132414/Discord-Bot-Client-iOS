import SwiftUI
import UIKit

@main
struct DiscordBotClientApp: App {
    @StateObject private var store = KeychainBotStore.shared
    @StateObject private var proxy = LocalBotProxyServer.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        LocalBotProxyServer.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .environmentObject(store)
                .environmentObject(proxy)
                .onChange(of: scenePhase) { newPhase in
                    if newPhase == .active {
                        LocalBotProxyServer.shared.ensureRunning()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                    LocalBotProxyServer.shared.ensureRunning()
                }
        }
    }
}
