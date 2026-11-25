import SwiftUI
import UIKit

struct DirectMessagesView: View {
    @EnvironmentObject private var vault: BotVaultStore
    @EnvironmentObject private var gateway: DiscordGatewayService

    @State private var searchQuery = ""
    @State private var showNewDMSheet = false
    @State private var activeDM: DiscordChannel?
    @State private var pushDM = false

    private let discordRed = Color(red: 0.949, green: 0.247, blue: 0.263)

    private var filteredDMs: [DiscordChannel] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return gateway.dmChannels }
        return gateway.dmChannels.filter { ch in
            ch.displayName.lowercased().contains(q)
            || (ch.recipients?.first?.username.lowercased().contains(q) ?? false)
            || (ch.recipients?.first?.id.contains(q) ?? false)
            || (gateway.lastMessageByChannel[ch.id]?.content.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        NavigationView {
            ZStack {
                vault.backgroundColor.ignoresSafeArea()

                if let ch = activeDM {
                    NavigationLink(
                        destination: ChannelChatView(channel: ch, guild: nil),
                        isActive: $pushDM
                    ) {
                        EmptyView()
                    }
                    .hidden()
                }

                VStack(spacing: 0) {
                    // Discord-style search bar
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.subheadline)
                            .foregroundColor(vault.secondaryTextColor)
                        TextField("Tìm hoặc bắt đầu cuộc trò chuyện...", text: $searchQuery)
                            .font(.subheadline)
                            .textFieldStyle(.plain)
                        if !searchQuery.isEmpty {
                            Button {
                                searchQuery = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundColor(vault.secondaryTextColor)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(vault.elevatedSurfaceColor)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                    Divider().background(vault.dividerColor)

                    if filteredDMs.isEmpty {
                        VStack(spacing: 14) {
                            Spacer()
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.system(size: 40))
                                .foregroundColor(vault.secondaryTextColor)
                            Text("Chưa có tin nhắn trực tiếp")
                                .font(.headline)
                                .foregroundColor(vault.primaryTextColor)
                            Text("Khi ai đó nhắn tin cho Bot hoặc bạn mở DM mới theo User ID, cuộc hội thoại sẽ hiển thị tại đây.")
                                .font(.caption)
                                .foregroundColor(vault.secondaryTextColor)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 28)

                            Button {
                                showNewDMSheet = true
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "plus")
                                    Text("Mở DM mới bằng User ID")
                                }
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(vault.accentColor)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            Spacer()
                        }
                    } else {
                        List {
                            ForEach(filteredDMs) { ch in
                                Button {
                                    activeDM = ch
                                    pushDM = true
                                } label: {
                                    dmRow(ch)
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(vault.backgroundColor)
                                .listRowSeparatorTint(vault.dividerColor)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        gateway.removeDMChannel(id: ch.id, vault: vault)
                                    } label: {
                                        Label("Ẩn DM", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .listStyle(.plain)
                    }
                }
            }
            .navigationTitle("Tin nhắn")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showNewDMSheet = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }
            .sheet(isPresented: $showNewDMSheet) {
                NewDMSheet { created in
                    activeDM = created
                    pushDM = true
                }
                .environmentObject(vault)
                .environmentObject(gateway)
            }
            .onChange(of: gateway.pendingJumpTarget?.channel.id) { _ in
                consumeJumpIfNeeded()
            }
            .onAppear {
                consumeJumpIfNeeded()
            }
        }
        .navigationViewStyle(.stack)
    }

    private func consumeJumpIfNeeded() {
        guard let target = gateway.pendingJumpTarget, target.guild == nil else { return }
        activeDM = target.channel
        pushDM = true
        gateway.pendingJumpTarget = nil
    }

    private func dmRow(_ ch: DiscordChannel) -> some View {
        let recipient = ch.recipients?.first
        let lastMsg = gateway.lastMessageByChannel[ch.id] ?? gateway.messagesByChannel[ch.id]?.last
        let unread = gateway.unreadCountByChannel[ch.id] ?? 0
        let preview = dmPreviewText(lastMsg)
        let timeLabel = DiscordDateParser.formatShort(lastMsg?.timestamp)

        return HStack(spacing: 12) {
            BotAvatarThumb(
                urlString: recipient?.avatarURL(size: 128)?.absoluteString,
                size: 44,
                accent: vault.accentColor
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(ch.displayName)
                        .font(.subheadline.weight(unread > 0 ? .bold : .semibold))
                        .foregroundColor(vault.primaryTextColor)
                        .lineLimit(1)

                    if recipient?.bot == true {
                        Text("APP")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(Color(red: 0.345, green: 0.396, blue: 0.949))
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }

                    Spacer()

                    if !timeLabel.isEmpty {
                        Text(timeLabel)
                            .font(.caption2)
                            .foregroundColor(unread > 0 ? vault.primaryTextColor : vault.secondaryTextColor)
                    }
                }

                HStack(spacing: 6) {
                    Text(preview)
                        .font(.caption)
                        .foregroundColor(unread > 0 ? vault.primaryTextColor.opacity(0.92) : vault.secondaryTextColor)
                        .lineLimit(1)

                    Spacer()

                    if unread > 0 {
                        Text(unread > 99 ? "99+" : "\(unread)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(discordRed)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func dmPreviewText(_ msg: DiscordMessage?) -> String {
        guard let msg = msg else { return "Chạm để xem lịch sử tin nhắn" }
        let prefix = (msg.author.id == gateway.botUser?.id) ? "Bạn: " : ""
        let trimmed = DiscordTextFormatter.renderCleanText(
            msg.content,
            guild: nil,
            mentions: msg.mentions,
            members: []
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return prefix + trimmed }
        if let st = msg.stickerItems?.first { return prefix + "[Sticker: \(st.name)]" }
        if !msg.attachments.isEmpty { return prefix + "[Đính kèm \(msg.attachments.first?.filename ?? "tệp")]" }
        if !msg.embeds.isEmpty { return prefix + "[Embed]" }
        return prefix + "Tin nhắn"
    }
}

private struct NewDMSheet: View {
    let onCreated: (DiscordChannel) -> Void

    @EnvironmentObject private var vault: BotVaultStore
    @EnvironmentObject private var gateway: DiscordGatewayService
    @Environment(\.dismiss) private var dismiss

    @State private var userIdInput = ""
    @State private var isOpening = false
    @State private var errMsg: String?

    var body: some View {
        NavigationView {
            Form {
                Section("Mở hội thoại mới với người dùng") {
                    HStack(spacing: 8) {
                        TextField("Nhập Discord User ID...", text: $userIdInput)
                            .keyboardType(.numberPad)
                        Button {
                            if let s = UIPasteboard.general.string {
                                userIdInput = s.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                        }
                        .buttonStyle(.plain)
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
                        Task { await createDM() }
                    } label: {
                        HStack {
                            Image(systemName: "paperplane.fill")
                            Text(isOpening ? "Đang mở kênh DM..." : "Mở kênh nhắn tin")
                            Spacer()
                            if isOpening { ProgressView() }
                        }
                    }
                    .disabled(isOpening || userIdInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Tin nhắn mới")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Hủy") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func createDM() async {
        let uid = userIdInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uid.isEmpty else { return }
        isOpening = true
        errMsg = nil
        defer { isOpening = false }
        do {
            let ch = try await gateway.openDM(recipientId: uid)
            dismiss()
            onCreated(ch)
        } catch {
            errMsg = error.localizedDescription
        }
    }
}
