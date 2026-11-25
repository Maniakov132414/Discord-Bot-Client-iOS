import SwiftUI
import UIKit

struct DirectMessagesView: View {
    @EnvironmentObject private var vault: BotVaultStore
    @EnvironmentObject private var gateway: DiscordGatewayService

    @State private var userIdInput: String = ""
    @State private var isOpeningDM = false
    @State private var dmError: String?
    @State private var activeDM: DiscordChannel?
    @State private var pushDM = false

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

                List {
                    Section("Nhắn tin mới bằng User ID") {
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

                        Button {
                            Task { await createAndOpenDM() }
                        } label: {
                            HStack {
                                Image(systemName: "paperplane.fill")
                                Text(isOpeningDM ? "Đang mở kênh DM..." : "Mở kênh nhắn tin")
                                Spacer()
                                if isOpeningDM { ProgressView() }
                            }
                        }
                        .disabled(isOpeningDM || userIdInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if let err = dmError {
                            Text(err)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }

                    Section("Kênh DM gần đây") {
                        if gateway.dmChannels.isEmpty {
                            Text("Chưa có cuộc hội thoại DM nào trong phiên hiện tại.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(gateway.dmChannels) { ch in
                                Button {
                                    activeDM = ch
                                    pushDM = true
                                } label: {
                                    HStack(spacing: 12) {
                                        BotAvatarThumb(
                                            urlString: ch.recipients?.first?.avatarURL(size: 96)?.absoluteString,
                                            size: 38,
                                            accent: vault.accentColor
                                        )
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(ch.displayName)
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundColor(vault.primaryTextColor)
                                            if let uid = ch.recipients?.first?.id {
                                                Text("ID: \(uid)")
                                                    .font(.caption2.monospaced())
                                                    .foregroundColor(vault.secondaryTextColor)
                                            }
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption)
                                            .foregroundColor(vault.secondaryTextColor)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Tin nhắn")
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationViewStyle(.stack)
    }

    private func createAndOpenDM() async {
        let uid = userIdInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uid.isEmpty else { return }
        isOpeningDM = true
        dmError = nil
        defer { isOpeningDM = false }
        do {
            let ch = try await gateway.openDM(recipientId: uid)
            userIdInput = ""
            activeDM = ch
            pushDM = true
        } catch {
            dmError = error.localizedDescription
        }
    }
}
