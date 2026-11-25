import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: KeychainBotStore
    @EnvironmentObject private var proxy: LocalBotProxyServer
    @StateObject private var webController = BotWebController()

    @State private var showManagerSheet = false
    @State private var pillOffset: CGSize = .zero
    @State private var dragAccumulated: CGSize = .zero

    private let discordBg = Color(red: 0.067, green: 0.071, blue: 0.078)

    var body: some View {
        ZStack(alignment: .topTrailing) {
            discordBg.ignoresSafeArea()

            if proxy.isReady || store.connectionMode == .customServer {
                BotClientWebView(
                    controller: webController,
                    mode: store.connectionMode,
                    localBaseURL: proxy.baseURL,
                    customServerURL: store.customServerURL
                )
                .ignoresSafeArea()
            } else {
                VStack(spacing: 14) {
                    ProgressView()
                        .tint(Color(red: 0.345, green: 0.396, blue: 0.949))
                        .scaleEffect(1.15)
                    Text("Đang khởi động Bot Proxy nội bộ...")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(Color(white: 0.78))
                }
            }

            // Subtle floating Bot Manager pill (draggable)
            Button {
                showManagerSheet = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "cpu")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Bot")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(.white.opacity(0.9))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.6)
                )
                .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 3)
            }
            .buttonStyle(.plain)
            .padding(.top, 54)
            .padding(.trailing, 12)
            .offset(
                x: dragAccumulated.width + pillOffset.width,
                y: dragAccumulated.height + pillOffset.height
            )
            .gesture(
                DragGesture()
                    .onChanged { val in
                        pillOffset = val.translation
                    }
                    .onEnded { val in
                        dragAccumulated.width += val.translation.width
                        dragAccumulated.height += val.translation.height
                        pillOffset = .zero
                    }
            )
        }
        .sheet(isPresented: $showManagerSheet) {
            BotManagerSheet(webController: webController)
                .environmentObject(store)
                .environmentObject(proxy)
        }
    }
}

struct BotManagerSheet: View {
    @EnvironmentObject private var store: KeychainBotStore
    @EnvironmentObject private var proxy: LocalBotProxyServer
    @ObservedObject var webController: BotWebController
    @Environment(\.dismiss) private var dismiss

    @State private var newBotName = ""
    @State private var newBotToken = ""
    @State private var customURLDraft = ""
    @State private var statusMessage: String?
    @State private var isValidatingNewBot = false

    private let blurple = Color(red: 0.345, green: 0.396, blue: 0.949)

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Picker("Chế độ", selection: $store.connectionMode) {
                        ForEach(ConnectionMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .onChange(of: store.connectionMode) { newMode in
                        if newMode == .standalone || !store.customServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            webController.loadTarget(
                                mode: newMode,
                                localBaseURL: proxy.baseURL,
                                customServerURL: store.customServerURL
                            )
                        }
                    }

                    if store.connectionMode == .standalone {
                        HStack {
                            Text("Loopback Proxy")
                            Spacer()
                            Text(proxy.isReady ? "127.0.0.1:\(proxy.port)" : "Đang khởi động")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(proxy.isReady ? .green : .orange)
                        }
                    } else {
                        TextField("https://your-dbc-server.example", text: $customURLDraft)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)

                        Button("Kết nối Server tùy chỉnh") {
                            store.customServerURL = customURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            webController.loadTarget(
                                mode: .customServer,
                                localBaseURL: proxy.baseURL,
                                customServerURL: store.customServerURL
                            )
                            dismiss()
                        }
                        .foregroundColor(blurple)
                    }
                } header: {
                    Text("Chế độ kết nối")
                } footer: {
                    Text("Chế độ Độc lập chạy máy chủ Proxy ngay trên iPhone, giữ Bot Token 100% trong iOS Keychain và không phụ thuộc Vercel/Web bên ngoài.")
                }

                Section("Bot Vault (Keychain)") {
                    if store.bots.isEmpty {
                        Text("Chưa có Bot nào được lưu. Đăng nhập ở màn hình Discord hoặc thêm nhanh bên dưới.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(store.bots) { bot in
                            let isActive = store.activeBotId == bot.id
                            Button {
                                webController.switchBotToken(
                                    bot.token,
                                    mode: store.connectionMode,
                                    localBaseURL: proxy.baseURL,
                                    customServerURL: store.customServerURL
                                )
                                store.activeBotId = bot.id
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    ZStack {
                                        Circle()
                                            .fill(blurple.opacity(0.22))
                                            .frame(width: 36, height: 36)
                                        Image(systemName: "cpu.fill")
                                            .font(.subheadline)
                                            .foregroundColor(blurple)
                                    }

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(bot.name)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundColor(.white)
                                        Text("\(bot.username.map { "@\($0) • " } ?? "")\(bot.maskedToken)")
                                            .font(.caption2.monospaced())
                                            .foregroundColor(.secondary)
                                    }

                                    Spacer()

                                    if isActive {
                                        Text("Đang dùng")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundColor(.green)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(Color.green.opacity(0.16))
                                            .clipShape(Capsule())
                                    }
                                }
                            }
                        }
                        .onDelete { offsets in
                            for idx in offsets {
                                let bot = store.bots[idx]
                                store.deleteBot(id: bot.id)
                            }
                        }
                    }
                }

                Section("Thêm Bot Token vào Vault") {
                    TextField("Tên gợi nhớ (tuỳ chọn)", text: $newBotName)
                    SecureField("Dán Discord Bot Token...", text: $newBotToken)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)

                    Button {
                        Task { await addAndActivateBot() }
                    } label: {
                        HStack {
                            Text(isValidatingNewBot ? "Đang xác thực..." : "Lưu & Đăng nhập Bot này")
                                .foregroundColor(blurple)
                            Spacer()
                            if isValidatingNewBot {
                                ProgressView().scaleEffect(0.8)
                            }
                        }
                    }
                    .disabled(isValidatingNewBot || KeychainBotStore.normalizeToken(newBotToken).isEmpty)
                }

                Section("Thao tác nhanh") {
                    Button {
                        webController.reload()
                        dismiss()
                    } label: {
                        Label("Reload Web", systemImage: "arrow.clockwise")
                    }

                    Button {
                        store.clearActiveTokenSelection()
                        webController.logoutBot(
                            mode: store.connectionMode,
                            localBaseURL: proxy.baseURL,
                            customServerURL: store.customServerURL
                        )
                        dismiss()
                    } label: {
                        Label("Đổi Bot Token (Logout)", systemImage: "rectangle.portrait.and.arrow.right")
                    }

                    Button(role: .destructive) {
                        webController.clearWebCache {
                            statusMessage = "Đã xóa cache Discord & tài nguyên."
                            webController.loadTarget(
                                mode: store.connectionMode,
                                localBaseURL: proxy.baseURL,
                                customServerURL: store.customServerURL
                            )
                        }
                    } label: {
                        Label("Xóa Cache", systemImage: "trash")
                    }
                }

                if let msg = statusMessage {
                    Section {
                        Text(msg)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Bot Manager")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Đóng") { dismiss() }
                }
            }
            .onAppear {
                customURLDraft = store.customServerURL
            }
        }
        .navigationViewStyle(.stack)
        .preferredColorScheme(.dark)
    }

    private func addAndActivateBot() async {
        let token = KeychainBotStore.normalizeToken(newBotToken)
        guard !token.isEmpty else { return }
        isValidatingNewBot = true
        statusMessage = nil

        var resolvedId: String?
        var resolvedName = newBotName.trimmingCharacters(in: .whitespacesAndNewlines)
        var resolvedUsername: String?
        var resolvedAvatar: String?

        if let url = URL(string: "https://canary.discord.com/api/v9/applications/@me?with_counts=true") {
            var req = URLRequest(url: url)
            req.timeoutInterval = 10
            req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("DiscordBot (https://github.com/aiko-chan-ai/DiscordBotClient, 3.10.7)", forHTTPHeaderField: "User-Agent")
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                let botDict = obj["bot"] as? [String: Any]
                resolvedId = (botDict?["id"] as? String) ?? (obj["id"] as? String)
                if resolvedName.isEmpty {
                    resolvedName = (obj["name"] as? String) ?? (botDict?["username"] as? String) ?? ""
                }
                resolvedUsername = botDict?["username"] as? String
                if let bid = resolvedId, let hash = (botDict?["avatar"] as? String) ?? (obj["icon"] as? String), !hash.isEmpty {
                    resolvedAvatar = "https://cdn.discordapp.com/avatars/\(bid)/\(hash).png"
                }
            }
        }

        store.saveOrUpdateBot(
            token: token,
            name: resolvedName,
            username: resolvedUsername,
            id: resolvedId,
            avatarURL: resolvedAvatar
        )
        newBotName = ""
        newBotToken = ""
        isValidatingNewBot = false

        webController.switchBotToken(
            token,
            mode: store.connectionMode,
            localBaseURL: proxy.baseURL,
            customServerURL: store.customServerURL
        )
        dismiss()
    }
}
