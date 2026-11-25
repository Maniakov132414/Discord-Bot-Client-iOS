import SwiftUI
import UIKit

struct BotAccountsSettingsView: View {
    @EnvironmentObject private var vault: BotVaultStore
    @EnvironmentObject private var gateway: DiscordGatewayService

    @State private var showAddBotSheet = false
    @State private var toastMessage: String?

    var body: some View {
        NavigationView {
            Form {
                if let active = vault.activeBot {
                    Section("Bot đang hoạt động") {
                        HStack(spacing: 12) {
                            BotAvatarThumb(urlString: active.avatarURL, size: 48, accent: vault.accentColor)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(active.name)
                                    .font(.headline)
                                    .foregroundColor(vault.primaryTextColor)
                                Text("\(active.username.map { "@\($0) • " } ?? "")ID: \(active.id)")
                                    .font(.caption.monospaced())
                                    .foregroundColor(vault.secondaryTextColor)
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(gateway.connectionState.color)
                                        .frame(width: 8, height: 8)
                                    Text("\(gateway.connectionState.title) • Shard \(vault.shardIndex)/\(vault.totalShards) • \(gateway.guilds.count) máy chủ")
                                        .font(.caption2)
                                        .foregroundColor(vault.secondaryTextColor)
                                }
                            }
                        }
                        .padding(.vertical, 4)

                        Button {
                            UIPasteboard.general.string = vault.inviteURL(for: active.id)
                            toastMessage = "Đã sao chép link mời Bot vào clipboard."
                        } label: {
                            Label("Sao chép link mời Bot (OAuth2)", systemImage: "link")
                        }
                    }
                }

                Section("Trạng thái & Hoạt động Bot") {
                    Picker("Trạng thái", selection: $vault.presenceStatus) {
                        ForEach(BotPresenceStatus.allCases) { st in
                            Text(st.title).tag(st)
                        }
                    }

                    Picker("Loại hoạt động", selection: $vault.activityType) {
                        ForEach(BotActivityType.allCases) { act in
                            Text(act.title).tag(act)
                        }
                    }

                    TextField("Nội dung hoạt động (tuỳ chọn)...", text: $vault.activityName)

                    Button {
                        gateway.updatePresence(
                            status: vault.presenceStatus,
                            activityType: vault.activityType,
                            activityName: vault.activityName
                        )
                        toastMessage = "Đã cập nhật trạng thái Presence lên Gateway."
                    } label: {
                        Label("Áp dụng trạng thái ngay", systemImage: "checkmark.circle.fill")
                    }
                }

                Section("Sharding") {
                    Stepper("Shard hiện tại: \(vault.shardIndex)", value: $vault.shardIndex, in: 0...max(0, vault.totalShards - 1))
                    Stepper("Tổng số Shard: \(vault.totalShards)", value: $vault.totalShards, in: 1...64)
                    Button {
                        if let active = vault.activeBot {
                            Task { await gateway.connect(account: active, vault: vault) }
                            toastMessage = "Đang kết nối lại với Shard \(vault.shardIndex)/\(vault.totalShards)."
                        }
                    } label: {
                        Label("Kết nối lại với cấu hình Shard này", systemImage: "arrow.triangle.2.circlepath")
                    }
                }

                Section("Tài khoản Bot Vault (Chỉ lưu trên máy)") {
                    ForEach(vault.bots) { bot in
                        let isActive = vault.activeBotId == bot.id
                        Button {
                            guard !isActive else { return }
                            vault.selectBot(id: bot.id)
                            Task { await gateway.connect(account: bot, vault: vault) }
                        } label: {
                            HStack(spacing: 10) {
                                BotAvatarThumb(urlString: bot.avatarURL, size: 34, accent: vault.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(bot.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundColor(vault.primaryTextColor)
                                    Text(bot.maskedToken)
                                        .font(.caption2.monospaced())
                                        .foregroundColor(vault.secondaryTextColor)
                                }
                                Spacer()
                                if isActive {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                }
                            }
                        }
                    }
                    .onDelete { offsets in
                        for idx in offsets {
                            let target = vault.bots[idx]
                            let wasActive = (vault.activeBotId == target.id)
                            vault.deleteBot(id: target.id)
                            if wasActive {
                                if let next = vault.activeBot {
                                    Task { await gateway.connect(account: next, vault: vault) }
                                } else {
                                    gateway.disconnect()
                                }
                            }
                        }
                    }

                    Button {
                        showAddBotSheet = true
                    } label: {
                        Label("Thêm Bot mới", systemImage: "plus.circle.fill")
                    }
                }

                Section("Giao diện") {
                    Picker("Chủ đề", selection: $vault.theme) {
                        ForEach(BotAppearanceTheme.allCases) { t in
                            Text(t.title).tag(t)
                        }
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(BotVaultStore.accentPresets, id: \.hex) { preset in
                                let selected = vault.accentHex.uppercased() == preset.hex
                                Button {
                                    vault.accentHex = preset.hex
                                } label: {
                                    Circle()
                                        .fill(Color(hex: preset.hex))
                                        .frame(width: 28, height: 28)
                                        .overlay(
                                            Circle()
                                                .strokeBorder(Color.white, lineWidth: selected ? 2.5 : 0)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("Hệ thống") {
                    Button {
                        vault.clearLocalCache()
                        toastMessage = "Đã xóa bộ nhớ đệm ảnh và API cục bộ."
                    } label: {
                        Label("Xóa Cache", systemImage: "trash")
                    }

                    Button(role: .destructive) {
                        gateway.disconnect()
                        vault.logout()
                    } label: {
                        Label("Đăng xuất phiên hiện tại", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }

                if let msg = toastMessage {
                    Section {
                        Text(msg)
                            .font(.caption)
                            .foregroundColor(vault.secondaryTextColor)
                    }
                }
            }
            .navigationTitle("Tài khoản & Cài đặt")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showAddBotSheet) {
                AddBotModalSheet()
                    .environmentObject(vault)
                    .environmentObject(gateway)
            }
        }
        .navigationViewStyle(.stack)
    }
}

private struct AddBotModalSheet: View {
    @EnvironmentObject private var vault: BotVaultStore
    @EnvironmentObject private var gateway: DiscordGatewayService
    @Environment(\.dismiss) private var dismiss

    @State private var nameDraft = ""
    @State private var tokenDraft = ""
    @State private var isLoading = false
    @State private var errMsg: String?

    var body: some View {
        NavigationView {
            Form {
                Section("Thông tin Bot mới") {
                    TextField("Tên gợi nhớ (tuỳ chọn)", text: $nameDraft)
                    SecureField("Dán Discord Bot Token...", text: $tokenDraft)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)

                    Button {
                        if let s = UIPasteboard.general.string {
                            tokenDraft = s
                        }
                    } label: {
                        Label("Dán từ Clipboard", systemImage: "doc.on.clipboard")
                    }
                }

                if let err = errMsg {
                    Section {
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                Section {
                    Button {
                        Task { await addBot() }
                    } label: {
                        HStack {
                            Text(isLoading ? "Đang xác thực..." : "Lưu & Chuyển sang Bot này")
                            Spacer()
                            if isLoading { ProgressView() }
                        }
                    }
                    .disabled(isLoading || BotVaultStore.normalizeToken(tokenDraft).isEmpty)
                }
            }
            .navigationTitle("Thêm Bot mới")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Đóng") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func addBot() async {
        let clean = BotVaultStore.normalizeToken(tokenDraft)
        guard !clean.isEmpty else { return }
        isLoading = true
        errMsg = nil
        defer { isLoading = false }
        do {
            let app = try await DiscordRESTClient.shared.fetchCurrentApplication(token: clean)
            let bot = app.bot
            let finalName = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? (app.name ?? bot?.username ?? "Discord Bot")
                : nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if let saved = vault.saveOrUpdateBot(
                token: clean,
                name: finalName,
                username: bot?.username,
                id: bot?.id ?? app.id,
                avatarURL: bot?.avatarURL(size: 128)?.absoluteString ?? app.iconURL?.absoluteString,
                flags: app.flags,
                approximateGuildCount: app.approximateGuildCount,
                activate: true
            ) {
                await gateway.connect(account: saved, vault: vault)
                dismiss()
            }
        } catch {
            errMsg = error.localizedDescription
        }
    }
}
