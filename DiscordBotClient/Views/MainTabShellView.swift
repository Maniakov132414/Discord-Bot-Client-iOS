import SwiftUI

struct MainTabShellView: View {
    @EnvironmentObject private var vault: BotVaultStore
    @EnvironmentObject private var gateway: DiscordGatewayService
    @State private var selectedTab: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            if let warning = gateway.intentWarningBanner {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.yellow)
                    Text(warning)
                        .font(.caption2)
                        .foregroundColor(.white)
                        .lineLimit(2)
                    Spacer()
                    Button {
                        gateway.intentWarningBanner = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.bold))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.85))
            }

            TabView(selection: $selectedTab) {
                ServersBrowserView()
                    .tabItem {
                        Label("Máy chủ", systemImage: "server.rack")
                    }
                    .tag(0)

                DirectMessagesView()
                    .tabItem {
                        Label("Tin nhắn", systemImage: "bubble.left.and.bubble.right.fill")
                    }
                    .tag(1)

                BotAccountsSettingsView()
                    .tabItem {
                        Label("Tài khoản", systemImage: "person.crop.circle.fill")
                    }
                    .tag(2)
            }
            .accentColor(vault.accentColor)
        }
        .background(vault.backgroundColor.ignoresSafeArea())
    }
}
