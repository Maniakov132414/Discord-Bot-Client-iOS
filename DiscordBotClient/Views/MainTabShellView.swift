import SwiftUI

struct MainTabShellView: View {
    @EnvironmentObject private var vault: BotVaultStore
    @EnvironmentObject private var gateway: DiscordGatewayService
    @State private var selectedTab: Int = 0

    var body: some View {
        ZStack(alignment: .top) {
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
                        .badge(gateway.totalGuildMentionCount)
                        .tag(0)

                    DirectMessagesView()
                        .tabItem {
                            Label("Tin nhắn", systemImage: "bubble.left.and.bubble.right.fill")
                        }
                        .badge(gateway.totalUnreadDMCount)
                        .tag(1)

                    BotAccountsSettingsView()
                        .tabItem {
                            Label("Tài khoản", systemImage: "person.crop.circle.fill")
                        }
                        .tag(2)
                }
                .accentColor(vault.accentColor)
            }

            if let banner = gateway.activeToastBanner {
                inAppToastBanner(banner)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: gateway.activeToastBanner?.id)
        .onChange(of: gateway.pendingTabSelection) { targetTab in
            if let tab = targetTab {
                selectedTab = tab
                gateway.pendingTabSelection = nil
            }
        }
        .background(vault.backgroundColor.ignoresSafeArea())
    }

    private func inAppToastBanner(_ banner: InAppNotificationBanner) -> some View {
        HStack(spacing: 10) {
            Button {
                gateway.pendingJumpTarget = (banner.channel, banner.guild)
                selectedTab = (banner.guild == nil) ? 1 : 0
                gateway.activeToastBanner = nil
            } label: {
                HStack(spacing: 10) {
                    BotAvatarThumb(
                        urlString: banner.avatarURL?.absoluteString,
                        size: 36,
                        accent: vault.accentColor
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(banner.title)
                            .font(.caption.weight(.bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text(banner.subtitle)
                            .font(.caption2)
                            .foregroundColor(Color(white: 0.82))
                            .lineLimit(1)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            Button {
                gateway.activeToastBanner = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(Color(white: 0.72))
                    .padding(6)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(red: 0.145, green: 0.153, blue: 0.176).opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(vault.accentColor.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 10, x: 0, y: 4)
    }
}
