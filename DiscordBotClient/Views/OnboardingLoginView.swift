import SwiftUI
import UIKit

struct OnboardingLoginView: View {
    @EnvironmentObject private var vault: BotVaultStore
    @EnvironmentObject private var gateway: DiscordGatewayService

    @State private var tokenDraft: String = ""
    @State private var customNameDraft: String = ""
    @State private var showTokenPlain = false
    @State private var isAuthenticating = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 22) {
                    // Header Brand
                    VStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(vault.accentColor.opacity(0.18))
                                .frame(width: 76, height: 76)
                            Image(systemName: "cpu.fill")
                                .font(.system(size: 34, weight: .semibold))
                                .foregroundColor(vault.accentColor)
                        }
                        Text("DiscordBot Client")
                            .font(.title2.weight(.bold))
                            .foregroundColor(vault.primaryTextColor)

                        HStack(spacing: 6) {
                            Image(systemName: "lock.shield.fill")
                                .font(.caption)
                                .foregroundColor(Color(red: 0.137, green: 0.647, blue: 0.353))
                            Text("Token chỉ lưu trên máy, không gửi đi đâu ngoài Discord")
                                .font(.caption)
                                .foregroundColor(vault.secondaryTextColor)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(vault.surfaceColor)
                        .clipShape(Capsule())
                    }
                    .padding(.top, 16)

                    // Saved Bots Section (1-tap login)
                    if !vault.bots.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Tài khoản Bot đã lưu")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(vault.secondaryTextColor)
                                .padding(.horizontal, 4)

                            VStack(spacing: 8) {
                                ForEach(vault.bots) { bot in
                                    HStack(spacing: 12) {
                                        Button {
                                            Task {
                                                vault.selectBot(id: bot.id)
                                                await gateway.connect(account: bot, vault: vault)
                                            }
                                        } label: {
                                            HStack(spacing: 12) {
                                                BotAvatarThumb(urlString: bot.avatarURL, size: 42, accent: vault.accentColor)
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(bot.name)
                                                        .font(.subheadline.weight(.semibold))
                                                        .foregroundColor(vault.primaryTextColor)
                                                        .lineLimit(1)
                                                    Text("\(bot.username.map { "@\($0) • " } ?? "")\(bot.maskedToken)")
                                                        .font(.caption.monospaced())
                                                        .foregroundColor(vault.secondaryTextColor)
                                                        .lineLimit(1)
                                                }
                                                Spacer()
                                                Image(systemName: "arrow.right.circle.fill")
                                                    .font(.title3)
                                                    .foregroundColor(vault.accentColor)
                                            }
                                        }
                                        .buttonStyle(.plain)

                                        Button(role: .destructive) {
                                            vault.deleteBot(id: bot.id)
                                        } label: {
                                            Image(systemName: "trash")
                                                .font(.subheadline)
                                                .foregroundColor(.red.opacity(0.85))
                                                .padding(8)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(12)
                                    .background(vault.surfaceColor)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }
                            }
                        }
                    }

                    // Token Input Card
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Thêm & Đăng nhập Bot mới")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(vault.primaryTextColor)

                        TextField("Tên gợi nhớ (tuỳ chọn)", text: $customNameDraft)
                            .textFieldStyle(.plain)
                            .padding(12)
                            .background(vault.elevatedSurfaceColor)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                        HStack(spacing: 8) {
                            Group {
                                if showTokenPlain {
                                    TextField("Dán Discord Bot Token...", text: $tokenDraft)
                                } else {
                                    SecureField("Dán Discord Bot Token...", text: $tokenDraft)
                                }
                            }
                            .textFieldStyle(.plain)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)

                            Button {
                                showTokenPlain.toggle()
                            } label: {
                                Image(systemName: showTokenPlain ? "eye.slash" : "eye")
                                    .foregroundColor(vault.secondaryTextColor)
                            }
                            .buttonStyle(.plain)

                            Button {
                                if let pasted = UIPasteboard.general.string {
                                    tokenDraft = pasted
                                }
                            } label: {
                                Image(systemName: "doc.on.clipboard")
                                    .foregroundColor(vault.accentColor)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(12)
                        .background(vault.elevatedSurfaceColor)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                        if let err = errorMessage ?? gateway.statusError {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                                Text(err)
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                        }

                        Button {
                            Task { await authenticateAndConnect() }
                        } label: {
                            HStack(spacing: 8) {
                                if isAuthenticating {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Image(systemName: "bolt.fill")
                                }
                                Text(isAuthenticating ? "Đang xác thực..." : "Đăng nhập Bot")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(vault.accentColor)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(isAuthenticating || BotVaultStore.normalizeToken(tokenDraft).isEmpty)
                        .opacity(BotVaultStore.normalizeToken(tokenDraft).isEmpty ? 0.55 : 1.0)
                    }
                    .padding(16)
                    .background(vault.surfaceColor)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .background(vault.backgroundColor.ignoresSafeArea())
            .navigationBarHidden(true)
        }
        .navigationViewStyle(.stack)
    }

    private func authenticateAndConnect() async {
        let clean = BotVaultStore.normalizeToken(tokenDraft)
        guard !clean.isEmpty else { return }
        isAuthenticating = true
        errorMessage = nil
        defer { isAuthenticating = false }

        do {
            let app = try await DiscordRESTClient.shared.fetchCurrentApplication(token: clean)
            let botUser = app.bot
            let nameDraft = customNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalName = !nameDraft.isEmpty ? nameDraft : (app.name ?? botUser?.username ?? "Discord Bot")
            let saved = vault.saveOrUpdateBot(
                token: clean,
                name: finalName,
                username: botUser?.username,
                id: botUser?.id ?? app.id,
                avatarURL: botUser?.avatarURL(size: 128)?.absoluteString ?? app.iconURL?.absoluteString,
                flags: app.flags,
                approximateGuildCount: app.approximateGuildCount,
                activate: true
            )
            tokenDraft = ""
            customNameDraft = ""
            if let saved = saved {
                await gateway.connect(account: saved, vault: vault)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct BotAvatarThumb: View {
    let urlString: String?
    let size: CGFloat
    let accent: Color

    var body: some View {
        Group {
            if let s = urlString, let url = URL(string: s) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var placeholder: some View {
        ZStack {
            Circle().fill(accent.opacity(0.22))
            Image(systemName: "cpu.fill")
                .font(.system(size: size * 0.44))
                .foregroundColor(accent)
        }
    }
}
