import Foundation
import SwiftUI
import Combine

enum GatewayConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting

    var title: String {
        switch self {
        case .disconnected: return "Ngoại tuyến"
        case .connecting: return "Đang kết nối..."
        case .connected: return "Trực tuyến"
        case .reconnecting: return "Đang kết nối lại..."
        }
    }

    var color: Color {
        switch self {
        case .disconnected: return .gray
        case .connecting, .reconnecting: return .orange
        case .connected: return Color(red: 0.137, green: 0.647, blue: 0.353)
        }
    }
}

@MainActor
final class DiscordGatewayService: ObservableObject {
    static let shared = DiscordGatewayService()

    @Published var connectionState: GatewayConnectionState = .disconnected
    @Published var statusError: String?
    @Published var intentWarningBanner: String?
    @Published var botUser: DiscordUser?
    @Published var application: DiscordApplication?
    @Published var applicationEmojis: [DiscordEmoji] = []
    @Published var guilds: [DiscordGuild] = []
    @Published var selectedGuildId: String?
    @Published var selectedChannelId: String?
    @Published var dmChannels: [DiscordChannel] = []
    @Published var messagesByChannel: [String: [DiscordMessage]] = [:]
    @Published var membersByGuild: [String: [DiscordMember]] = [:]
    @Published var typingUsersByChannel: [String: [String: Date]] = [:]
    @Published var loadingChannelIds: Set<String> = []
    @Published var hasMoreOlderByChannel: [String: Bool] = [:]

    private let defaultGatewayURL = "wss://gateway.discord.gg/?v=10&encoding=json"
    private let unprivilegedIntents: Int64 = 3_243_773
    private let rest = DiscordRESTClient.shared
    private let decoder = JSONDecoder()

    private var urlSession: URLSession!
    private var delegateProxy: GatewaySessionDelegate!
    private var webSocketTask: URLSessionWebSocketTask?
    private var heartbeatTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var typingCleanupTask: Task<Void, Never>?

    private var activeToken: String = ""
    private var activeIntents: Int64 = 3_243_773
    private var forcedUnprivileged = false
    private var sessionId: String?
    private var resumeGatewayURL: String?
    private var lastSequence: Int?
    private var heartbeatIntervalMs: Int = 41_250
    private var heartbeatAcked = true
    private var shouldStayConnected = false
    private var shardIndex: Int = 0
    private var totalShards: Int = 1

    private init() {
        let proxy = GatewaySessionDelegate { [weak self] closeCode in
            Task { @MainActor [weak self] in
                self?.handleSocketClosed(code: closeCode)
            }
        }
        self.delegateProxy = proxy
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        self.urlSession = URLSession(configuration: cfg, delegate: proxy, delegateQueue: nil)
        startTypingCleaner()
    }

    var currentToken: String { activeToken }

    func connect(account: SavedBotAccount, vault: BotVaultStore) async {
        let clean = BotVaultStore.normalizeToken(account.token)
        guard !clean.isEmpty else { return }

        disconnect(keepData: false)
        activeToken = clean
        forcedUnprivileged = false
        intentWarningBanner = nil
        statusError = nil
        shardIndex = max(0, min(vault.shardIndex, max(0, vault.totalShards - 1)))
        totalShards = max(1, vault.totalShards)
        shouldStayConnected = true
        connectionState = .connecting

        do {
            let app = try await rest.fetchCurrentApplication(token: clean)
            self.application = app
            let flags = app.flags ?? account.flags ?? 0
            self.activeIntents = computeAllowedIntents(fromFlags: flags)
            if let approx = app.approximateGuildCount, approx > 2500 {
                let suggested = max(1, Int(ceil(Double(approx) / 2500.0)))
                vault.totalShards = suggested
                self.totalShards = suggested
                self.shardIndex = min(self.shardIndex, suggested - 1)
            }
            if let bot = app.bot {
                self.botUser = bot
                let avatarStr = bot.avatarURL(size: 128)?.absoluteString
                vault.saveOrUpdateBot(
                    token: clean,
                    name: app.name ?? bot.username,
                    username: bot.username,
                    id: bot.id,
                    avatarURL: avatarStr,
                    flags: app.flags,
                    approximateGuildCount: app.approximateGuildCount,
                    activate: true
                )
            }
        } catch {
            self.activeIntents = computeAllowedIntents(fromFlags: account.flags ?? 0)
        }

        openWebSocket(urlString: defaultGatewayURL)
    }

    func reconnectIfNeeded(vault: BotVaultStore) async {
        guard let active = vault.activeBot else { return }
        if connectionState == .disconnected {
            await connect(account: active, vault: vault)
        }
    }

    func disconnect(keepData: Bool = false) {
        shouldStayConnected = false
        heartbeatTask?.cancel()
        heartbeatTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        sessionId = nil
        resumeGatewayURL = nil
        lastSequence = nil
        connectionState = .disconnected
        if !keepData {
            guilds = []
            dmChannels = []
            applicationEmojis = []
            messagesByChannel = [:]
            membersByGuild = [:]
            typingUsersByChannel = [:]
            selectedGuildId = nil
            selectedChannelId = nil
            botUser = nil
            application = nil
        }
    }

    func updatePresence(
        status: BotPresenceStatus,
        activityType: BotActivityType,
        activityName: String,
        streamURL: String = ""
    ) {
        let activities = buildActivitiesPayload(
            activityType: activityType,
            activityName: activityName,
            streamURL: streamURL
        )
        let d: [String: Any] = [
            "since": NSNull(),
            "activities": activities,
            "status": status.rawValue,
            "afk": false
        ]
        sendGatewayPayload(op: 3, d: d)
    }

    func applyPresenceAndPlatform(vault: BotVaultStore, previousPlatform: BotClientPlatform) async {
        if vault.clientPlatform != previousPlatform, let active = vault.activeBot {
            await connect(account: active, vault: vault)
        } else {
            updatePresence(
                status: vault.presenceStatus,
                activityType: vault.activityType,
                activityName: vault.activityName,
                streamURL: vault.activityStreamURL
            )
        }
    }

    private func buildActivitiesPayload(
        activityType: BotActivityType,
        activityName: String,
        streamURL: String
    ) -> [[String: Any]] {
        let trimmed = activityName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        switch activityType {
        case .custom:
            return [[
                "name": "Custom Status",
                "type": 4,
                "state": trimmed
            ]]
        case .streaming:
            var dict: [String: Any] = [
                "name": trimmed,
                "type": 1
            ]
            let sURL = streamURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sURL.isEmpty {
                dict["url"] = sURL
            }
            return [dict]
        default:
            return [[
                "name": trimmed,
                "type": activityType.rawValue
            ]]
        }
    }

    func requestGuildMembers(guildId: String, query: String = "", limit: Int = 100) {
        let d: [String: Any] = [
            "guild_id": guildId,
            "query": query,
            "limit": limit
        ]
        sendGatewayPayload(op: 8, d: d)
    }

    // MARK: - Intents & Socket Lifecycle

    private func computeAllowedIntents(fromFlags flags: Int64) -> Int64 {
        var intents: Int64 = 53_608_447
        let hasPresence = (flags & ((1 << 12) | (1 << 13))) != 0
        let hasMembers = (flags & ((1 << 14) | (1 << 15))) != 0
        let hasMessageContent = (flags & ((1 << 18) | (1 << 19))) != 0
        if !hasPresence { intents &= ~(1 << 8) }
        if !hasMembers { intents &= ~(1 << 1) }
        if !hasMessageContent { intents &= ~(1 << 15) }
        return intents
    }

    private func openWebSocket(urlString: String) {
        guard shouldStayConnected, let url = URL(string: urlString) else { return }
        receiveTask?.cancel()
        heartbeatTask?.cancel()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)

        let task = urlSession.webSocketTask(with: url)
        task.maximumMessageSize = 16 * 1024 * 1024
        self.webSocketTask = task
        task.resume()
        receiveLoop(for: task)
    }

    private func receiveLoop(for task: URLSessionWebSocketTask) {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                do {
                    let message = try await task.receive()
                    var data: Data?
                    switch message {
                    case .string(let text):
                        data = text.data(using: .utf8)
                    case .data(let raw):
                        data = raw
                    @unknown default:
                        break
                    }
                    if let data = data {
                        await self.handleGatewayPacket(data)
                    }
                } catch {
                    let closeCode = task.closeCode.rawValue
                    await self.handleSocketClosed(code: closeCode)
                    return
                }
            }
        }
    }

    private func handleSocketClosed(code: Int) {
        guard shouldStayConnected else { return }
        heartbeatTask?.cancel()
        heartbeatTask = nil

        if code == 4004 {
            statusError = "Bot Token không hợp lệ hoặc đã bị thu hồi (4004)."
            shouldStayConnected = false
            connectionState = .disconnected
            return
        }

        if code == 4014 && !forcedUnprivileged {
            forcedUnprivileged = true
            activeIntents = unprivilegedIntents
            sessionId = nil
            lastSequence = nil
            intentWarningBanner = "Bot chưa bật Privileged Intents trên Developer Portal; đã tự động chuyển sang chế độ Intents cơ bản."
            connectionState = .reconnecting
            openWebSocket(urlString: defaultGatewayURL)
            return
        }

        connectionState = .reconnecting
        let canResume = (sessionId != nil && resumeGatewayURL != nil && ![4007, 4009].contains(code))
        let targetURL = canResume ? (resumeGatewayURL ?? defaultGatewayURL) : defaultGatewayURL
        if !canResume {
            sessionId = nil
            lastSequence = nil
        }

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await self?.openWebSocket(urlString: targetURL)
        }
    }

    private func handleGatewayPacket(_ data: Data) async {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let op = obj["op"] as? Int else {
            return
        }
        if let s = obj["s"] as? Int {
            lastSequence = s
        }

        switch op {
        case 10:
            if let d = obj["d"] as? [String: Any],
               let interval = d["heartbeat_interval"] as? Int {
                heartbeatIntervalMs = interval
            }
            heartbeatAcked = true
            startHeartbeatLoop()
            if let sid = sessionId, let seq = lastSequence {
                sendResume(sessionId: sid, seq: seq)
            } else {
                sendIdentify()
            }

        case 11:
            heartbeatAcked = true

        case 1:
            sendHeartbeat()

        case 7:
            connectionState = .reconnecting
            let target = resumeGatewayURL ?? defaultGatewayURL
            openWebSocket(urlString: target)

        case 9:
            let resumable = (obj["d"] as? Bool) ?? false
            if !resumable {
                sessionId = nil
                lastSequence = nil
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self = self, self.shouldStayConnected else { return }
                if resumable, let sid = self.sessionId, let seq = self.lastSequence {
                    self.sendResume(sessionId: sid, seq: seq)
                } else {
                    self.sendIdentify()
                }
            }

        case 0:
            guard let eventName = obj["t"] as? String else { return }
            let d = obj["d"]
            await handleDispatchEvent(name: eventName, payload: d)

        default:
            break
        }
    }

    private func startHeartbeatLoop() {
        heartbeatTask?.cancel()
        let intervalMs = max(5000, heartbeatIntervalMs)
        heartbeatTask = Task { [weak self] in
            let jitter = Double.random(in: 0.15...0.65)
            try? await Task.sleep(nanoseconds: UInt64(Double(intervalMs) * jitter * 1_000_000))
            while !Task.isCancelled {
                guard let self = self, self.shouldStayConnected else { return }
                if !self.heartbeatAcked {
                    await self.handleSocketClosed(code: 1006)
                    return
                }
                self.heartbeatAcked = false
                self.sendHeartbeat()
                try? await Task.sleep(nanoseconds: UInt64(intervalMs) * 1_000_000)
            }
        }
    }

    private func sendHeartbeat() {
        let seqVal: Any = lastSequence ?? NSNull()
        sendGatewayPayload(op: 1, d: seqVal)
    }

    private func sendIdentify() {
        let vault = BotVaultStore.shared
        let activities = buildActivitiesPayload(
            activityType: vault.activityType,
            activityName: vault.activityName,
            streamURL: vault.activityStreamURL
        )
        let d: [String: Any] = [
            "token": activeToken,
            "intents": activeIntents,
            "shard": [shardIndex, max(1, totalShards)],
            "properties": vault.clientPlatform.identifyProperties,
            "presence": [
                "status": vault.presenceStatus.rawValue,
                "activities": activities,
                "since": NSNull(),
                "afk": false
            ]
        ]
        sendGatewayPayload(op: 2, d: d)
    }

    private func sendResume(sessionId: String, seq: Int) {
        let d: [String: Any] = [
            "token": activeToken,
            "session_id": sessionId,
            "seq": seq
        ]
        sendGatewayPayload(op: 6, d: d)
    }

    private func sendGatewayPayload(op: Int, d: Any) {
        guard let task = webSocketTask else { return }
        let payload: [String: Any] = ["op": op, "d": d]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    // MARK: - Dispatch Event Handlers

    private func handleDispatchEvent(name: String, payload: Any?) async {
        switch name {
        case "READY":
            guard let dict = payload as? [String: Any] else { return }
            if let sid = dict["session_id"] as? String { self.sessionId = sid }
            if let rURL = dict["resume_gateway_url"] as? String {
                self.resumeGatewayURL = rURL.hasSuffix("/") ? "\(rURL)?v=10&encoding=json" : "\(rURL)/?v=10&encoding=json"
            }
            if let userObj = dict["user"], let u: DiscordUser = decodeJSON(userObj) {
                self.botUser = u
            }
            if let privs = dict["private_channels"] as? [[String: Any]] {
                self.dmChannels = privs.compactMap { decodeJSON($0) }
            }
            connectionState = .connected
            statusError = nil
            await loadApplicationEmojis()

        case "RESUMED":
            connectionState = .connected
            statusError = nil

        case "GUILD_CREATE":
            guard let dict = payload as? [String: Any],
                  var guild: DiscordGuild = decodeJSON(dict) else { return }
            if let membersArr = dict["members"] as? [[String: Any]] {
                let decodedMembers: [DiscordMember] = membersArr.compactMap { decodeJSON($0) }
                for m in decodedMembers {
                    upsertMember(guildId: guild.id, member: m)
                }
            }
            if let threadsArr = dict["threads"] as? [[String: Any]] {
                let threads: [DiscordChannel] = threadsArr.compactMap { decodeJSON($0) }
                for th in threads where !guild.channels.contains(where: { $0.id == th.id }) {
                    guild.channels.append(th)
                }
            }
            if let idx = guilds.firstIndex(where: { $0.id == guild.id }) {
                guilds[idx] = guild
            } else {
                guilds.append(guild)
            }
            if selectedGuildId == nil {
                selectedGuildId = guild.id
            }

        case "GUILD_UPDATE":
            guard let dict = payload as? [String: Any],
                  let updated: DiscordGuild = decodeJSON(dict) else { return }
            if let idx = guilds.firstIndex(where: { $0.id == updated.id }) {
                var merged = guilds[idx]
                merged.name = updated.name
                merged.icon = updated.icon
                merged.roles = updated.roles.isEmpty ? merged.roles : updated.roles
                merged.emojis = updated.emojis.isEmpty ? merged.emojis : updated.emojis
                guilds[idx] = merged
            }

        case "GUILD_EMOJIS_UPDATE":
            guard let dict = payload as? [String: Any],
                  let gid = dict["guild_id"] as? String,
                  let emojisArr = dict["emojis"] as? [[String: Any]],
                  let gIdx = guilds.firstIndex(where: { $0.id == gid }) else { return }
            guilds[gIdx].emojis = emojisArr.compactMap { decodeJSON($0) }

        case "GUILD_DELETE":
            if let dict = payload as? [String: Any], let gid = dict["id"] as? String {
                guilds.removeAll(where: { $0.id == gid })
                if selectedGuildId == gid {
                    selectedGuildId = guilds.first?.id
                }
            }

        case "CHANNEL_CREATE", "THREAD_CREATE":
            guard let dict = payload as? [String: Any],
                  let ch: DiscordChannel = decodeJSON(dict) else { return }
            if ch.type == 1 || ch.type == 3 {
                if !dmChannels.contains(where: { $0.id == ch.id }) {
                    dmChannels.insert(ch, at: 0)
                }
            } else if let gid = ch.guildId, let gIdx = guilds.firstIndex(where: { $0.id == gid }) {
                if !guilds[gIdx].channels.contains(where: { $0.id == ch.id }) {
                    guilds[gIdx].channels.append(ch)
                }
            }

        case "CHANNEL_UPDATE", "THREAD_UPDATE":
            guard let dict = payload as? [String: Any],
                  let ch: DiscordChannel = decodeJSON(dict),
                  let gid = ch.guildId,
                  let gIdx = guilds.firstIndex(where: { $0.id == gid }),
                  let cIdx = guilds[gIdx].channels.firstIndex(where: { $0.id == ch.id }) else { return }
            guilds[gIdx].channels[cIdx] = ch

        case "CHANNEL_DELETE", "THREAD_DELETE":
            guard let dict = payload as? [String: Any],
                  let cid = dict["id"] as? String else { return }
            if let gid = dict["guild_id"] as? String,
               let gIdx = guilds.firstIndex(where: { $0.id == gid }) {
                guilds[gIdx].channels.removeAll(where: { $0.id == cid })
            }
            dmChannels.removeAll(where: { $0.id == cid })

        case "MESSAGE_CREATE":
            guard let dict = payload as? [String: Any],
                  let msg: DiscordMessage = decodeJSON(dict) else { return }
            var arr = messagesByChannel[msg.channelId] ?? []
            if !arr.contains(where: { $0.id == msg.id }) {
                arr.append(msg)
                messagesByChannel[msg.channelId] = arr
            }
            harvestMember(from: msg)
            if var typers = typingUsersByChannel[msg.channelId] {
                typers.removeValue(forKey: msg.author.id)
                typingUsersByChannel[msg.channelId] = typers
            }

        case "MESSAGE_UPDATE":
            guard let dict = payload as? [String: Any],
                  let mid = dict["id"] as? String,
                  let cid = dict["channel_id"] as? String,
                  var arr = messagesByChannel[cid],
                  let idx = arr.firstIndex(where: { $0.id == mid }) else { return }
            if let full: DiscordMessage = decodeJSON(dict) {
                arr[idx] = full
            } else {
                if let content = dict["content"] as? String {
                    arr[idx].content = content
                }
                if let edited = dict["edited_timestamp"] as? String {
                    arr[idx].editedTimestamp = edited
                }
                if let pinned = dict["pinned"] as? Bool {
                    arr[idx].pinned = pinned
                }
                if let flags = dict["flags"] as? Int {
                    arr[idx].flags = flags
                }
                if let embedsRaw = dict["embeds"], let embeds: [DiscordEmbed] = decodeJSON(embedsRaw) {
                    arr[idx].embeds = embeds
                }
                if let compsRaw = dict["components"], let comps: LossyArray<DiscordComponent> = decodeJSON(compsRaw) {
                    arr[idx].components = comps.elements
                }
            }
            messagesByChannel[cid] = arr

        case "MESSAGE_DELETE":
            guard let dict = payload as? [String: Any],
                  let mid = dict["id"] as? String,
                  let cid = dict["channel_id"] as? String else { return }
            messagesByChannel[cid]?.removeAll(where: { $0.id == mid })

        case "MESSAGE_DELETE_BULK":
            guard let dict = payload as? [String: Any],
                  let ids = dict["ids"] as? [String],
                  let cid = dict["channel_id"] as? String else { return }
            let idSet = Set(ids)
            messagesByChannel[cid]?.removeAll(where: { idSet.contains($0.id) })

        case "MESSAGE_REACTION_ADD":
            guard let dict = payload as? [String: Any],
                  let cid = dict["channel_id"] as? String,
                  let mid = dict["message_id"] as? String,
                  let uid = dict["user_id"] as? String,
                  let emojiRaw = dict["emoji"],
                  let emoji: DiscordPartialEmoji = decodeJSON(emojiRaw),
                  var arr = messagesByChannel[cid],
                  let idx = arr.firstIndex(where: { $0.id == mid }) else { return }
            var rxns = arr[idx].reactions ?? []
            let isMe = (uid == botUser?.id)
            if let rIdx = rxns.firstIndex(where: { $0.emoji.apiIdentifier == emoji.apiIdentifier }) {
                rxns[rIdx].count += 1
                if isMe { rxns[rIdx].me = true }
            } else {
                rxns.append(DiscordReaction(count: 1, me: isMe, emoji: emoji))
            }
            arr[idx].reactions = rxns
            messagesByChannel[cid] = arr

        case "MESSAGE_REACTION_REMOVE":
            guard let dict = payload as? [String: Any],
                  let cid = dict["channel_id"] as? String,
                  let mid = dict["message_id"] as? String,
                  let uid = dict["user_id"] as? String,
                  let emojiRaw = dict["emoji"],
                  let emoji: DiscordPartialEmoji = decodeJSON(emojiRaw),
                  var arr = messagesByChannel[cid],
                  let idx = arr.firstIndex(where: { $0.id == mid }) else { return }
            var rxns = arr[idx].reactions ?? []
            let isMe = (uid == botUser?.id)
            if let rIdx = rxns.firstIndex(where: { $0.emoji.apiIdentifier == emoji.apiIdentifier }) {
                rxns[rIdx].count = max(0, rxns[rIdx].count - 1)
                if isMe { rxns[rIdx].me = false }
                if rxns[rIdx].count == 0 {
                    rxns.remove(at: rIdx)
                }
            }
            arr[idx].reactions = rxns
            messagesByChannel[cid] = arr

        case "TYPING_START":
            guard let dict = payload as? [String: Any],
                  let cid = dict["channel_id"] as? String,
                  let uid = dict["user_id"] as? String,
                  uid != botUser?.id else { return }
            let memberDict = dict["member"] as? [String: Any]
            let userDict = memberDict?["user"] as? [String: Any]
            let name = (memberDict?["nick"] as? String)
                ?? (userDict?["global_name"] as? String)
                ?? (userDict?["username"] as? String)
                ?? membersByGuild[dict["guild_id"] as? String ?? ""]?.first(where: { $0.user?.id == uid })?.displayName()
                ?? "Ai đó"
            var map = typingUsersByChannel[cid] ?? [:]
            map[name] = Date().addingTimeInterval(8)
            typingUsersByChannel[cid] = map

        case "GUILD_MEMBERS_CHUNK":
            guard let dict = payload as? [String: Any],
                  let gid = dict["guild_id"] as? String,
                  let membersArr = dict["members"] as? [[String: Any]] else { return }
            for raw in membersArr {
                if let m: DiscordMember = decodeJSON(raw) {
                    upsertMember(guildId: gid, member: m)
                }
            }

        case "INTERACTION_CREATE":
            guard let dict = payload as? [String: Any],
                  let interactionType = dict["type"] as? Int,
                  interactionType == 3,
                  let interactionId = dict["id"] as? String,
                  let interactionToken = dict["token"] as? String else { return }
            let dataDict = dict["data"] as? [String: Any]
            let customId = (dataDict?["custom_id"] as? String) ?? ""
            let rule = BotVaultStore.shared.buttonAutoReplies.first(where: { $0.customId == customId })
            if let rule = rule {
                try? await rest.respondToInteraction(
                    interactionId: interactionId,
                    interactionToken: interactionToken,
                    type: 4,
                    content: rule.replyContent,
                    ephemeral: rule.ephemeral,
                    token: activeToken
                )
            } else {
                try? await rest.respondToInteraction(
                    interactionId: interactionId,
                    interactionToken: interactionToken,
                    type: 6,
                    token: activeToken
                )
            }

        default:
            break
        }
    }

    private func loadApplicationEmojis() async {
        guard let appId = application?.id ?? botUser?.id, !activeToken.isEmpty else { return }
        if let items = try? await rest.fetchApplicationEmojis(applicationId: appId, token: activeToken) {
            self.applicationEmojis = items
        }
    }

    private func harvestMember(from msg: DiscordMessage) {
        let resolvedGuildId = msg.guildId ?? guilds.first(where: { $0.channels.contains(where: { $0.id == msg.channelId }) })?.id
        guard let gid = resolvedGuildId else { return }
        if var m = msg.member {
            m.user = m.user ?? msg.author
            upsertMember(guildId: gid, member: m)
        } else {
            // Ensure author still shows in members list even without GUILD_MEMBERS intent
            let existing = membersByGuild[gid]?.first(where: { $0.user?.id == msg.author.id })
            if existing == nil {
                upsertMember(guildId: gid, member: DiscordMember(user: msg.author, nick: nil, roles: [], avatar: nil, joinedAt: nil))
            }
        }
    }

    private func upsertMember(guildId: String, member: DiscordMember) {
        guard let uid = member.user?.id else { return }
        var list = membersByGuild[guildId] ?? []
        if let idx = list.firstIndex(where: { $0.user?.id == uid }) {
            var merged = member
            if merged.roles.isEmpty && !list[idx].roles.isEmpty {
                merged.roles = list[idx].roles
            }
            if merged.nick == nil { merged.nick = list[idx].nick }
            list[idx] = merged
        } else {
            list.append(member)
        }
        membersByGuild[guildId] = list
    }

    private func decodeJSON<T: Decodable>(_ obj: Any) -> T? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    private func startTypingCleaner() {
        typingCleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self = self else { return }
                let now = Date()
                for (cid, map) in self.typingUsersByChannel {
                    let filtered = map.filter { $0.value > now }
                    if filtered.count != map.count {
                        self.typingUsersByChannel[cid] = filtered
                    }
                }
            }
        }
    }

    // MARK: - High-Level Actions

    func refreshGuildDetailsIfNeeded(_ guildId: String) async {
        guard !activeToken.isEmpty else { return }
        if let gIdx = guilds.firstIndex(where: { $0.id == guildId }), guilds[gIdx].emojis.isEmpty {
            if let emojis = try? await rest.fetchGuildEmojis(guildId: guildId, token: activeToken) {
                guilds[gIdx].emojis = emojis
            }
        }
        if (membersByGuild[guildId]?.count ?? 0) < 20 {
            requestGuildMembers(guildId: guildId, query: "", limit: 100)
            if let restMembers = try? await rest.fetchGuildMembers(guildId: guildId, limit: 200, token: activeToken) {
                for m in restMembers {
                    upsertMember(guildId: guildId, member: m)
                }
            }
        }
    }

    func loadMessages(channelId: String) async {
        guard !activeToken.isEmpty else { return }
        loadingChannelIds.insert(channelId)
        defer { loadingChannelIds.remove(channelId) }
        do {
            let list = try await rest.fetchMessages(channelId: channelId, limit: 50, token: activeToken)
            messagesByChannel[channelId] = list
            hasMoreOlderByChannel[channelId] = list.count >= 50
            for m in list { harvestMember(from: m) }
        } catch {
            statusError = error.localizedDescription
        }
    }

    func loadOlderMessages(channelId: String) async {
        guard !activeToken.isEmpty,
              let oldest = messagesByChannel[channelId]?.first?.id,
              !loadingChannelIds.contains(channelId) else { return }
        loadingChannelIds.insert(channelId)
        defer { loadingChannelIds.remove(channelId) }
        do {
            let older = try await rest.fetchMessages(channelId: channelId, before: oldest, limit: 50, token: activeToken)
            var current = messagesByChannel[channelId] ?? []
            let existingIds = Set(current.map(\.id))
            let newItems = older.filter { !existingIds.contains($0.id) }
            current.insert(contentsOf: newItems, at: 0)
            messagesByChannel[channelId] = current
            hasMoreOlderByChannel[channelId] = older.count >= 50
            for m in newItems { harvestMember(from: m) }
        } catch {
            statusError = error.localizedDescription
        }
    }

    func sendMessage(
        channelId: String,
        content: String,
        embeds: [DiscordEmbed] = [],
        components: [DiscordComponent] = [],
        flags: Int? = nil,
        replyToMessageId: String? = nil,
        attachments: [MediaUploadItem] = []
    ) async throws {
        let sent = try await rest.sendMessage(
            channelId: channelId,
            content: content,
            embeds: embeds,
            components: components,
            flags: flags,
            replyToMessageId: replyToMessageId,
            attachments: attachments,
            token: activeToken
        )
        var arr = messagesByChannel[channelId] ?? []
        if !arr.contains(where: { $0.id == sent.id }) {
            arr.append(sent)
            messagesByChannel[channelId] = arr
        }
        harvestMember(from: sent)
    }

    func editMessage(
        channelId: String,
        messageId: String,
        content: String?,
        embeds: [DiscordEmbed]?,
        components: [DiscordComponent]? = nil,
        flags: Int? = nil
    ) async throws {
        let updated = try await rest.editMessage(
            channelId: channelId,
            messageId: messageId,
            content: content,
            embeds: embeds,
            components: components,
            flags: flags,
            token: activeToken
        )
        if var arr = messagesByChannel[channelId], let idx = arr.firstIndex(where: { $0.id == messageId }) {
            arr[idx] = updated
            messagesByChannel[channelId] = arr
        }
    }

    func deleteMessage(channelId: String, messageId: String) async throws {
        try await rest.deleteMessage(channelId: channelId, messageId: messageId, token: activeToken)
        messagesByChannel[channelId]?.removeAll(where: { $0.id == messageId })
    }

    func purgeRecentMessages(channelId: String, count: Int) async throws {
        let current = messagesByChannel[channelId] ?? []
        let targetIds = current.suffix(min(max(count, 1), 100)).map(\.id)
        guard !targetIds.isEmpty else { return }
        try await rest.bulkDeleteMessages(channelId: channelId, messageIds: targetIds, token: activeToken)
        let idSet = Set(targetIds)
        messagesByChannel[channelId]?.removeAll(where: { idSet.contains($0.id) })
    }

    func toggleReaction(channelId: String, messageId: String, emojiIdentifier: String, currentlyMine: Bool) async {
        do {
            try await rest.toggleReaction(
                channelId: channelId,
                messageId: messageId,
                emojiIdentifier: emojiIdentifier,
                add: !currentlyMine,
                token: activeToken
            )
        } catch {
            statusError = error.localizedDescription
        }
    }

    func pinMessage(channelId: String, messageId: String, pin: Bool) async {
        do {
            try await rest.pinMessage(channelId: channelId, messageId: messageId, pin: pin, token: activeToken)
            if var arr = messagesByChannel[channelId], let idx = arr.firstIndex(where: { $0.id == messageId }) {
                arr[idx].pinned = pin
                messagesByChannel[channelId] = arr
            }
        } catch {
            statusError = error.localizedDescription
        }
    }

    func openDM(recipientId: String) async throws -> DiscordChannel {
        let channel = try await rest.createDM(recipientId: recipientId, token: activeToken)
        if !dmChannels.contains(where: { $0.id == channel.id }) {
            dmChannels.insert(channel, at: 0)
        }
        return channel
    }

    func searchMembers(guildId: String, query: String) async -> [DiscordMember] {
        do {
            let found = try await rest.fetchGuildMembers(guildId: guildId, limit: 100, query: query, token: activeToken)
            for m in found {
                upsertMember(guildId: guildId, member: m)
            }
            return found
        } catch {
            return membersByGuild[guildId] ?? []
        }
    }
}

private final class GatewaySessionDelegate: NSObject, URLSessionWebSocketDelegate {
    private let onClose: (Int) -> Void

    init(onClose: @escaping (Int) -> Void) {
        self.onClose = onClose
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        onClose(closeCode.rawValue)
    }
}
