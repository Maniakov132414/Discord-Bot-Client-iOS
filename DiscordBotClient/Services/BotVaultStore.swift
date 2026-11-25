import Foundation
import Security
import SwiftUI
import Combine

@MainActor
final class BotVaultStore: ObservableObject {
    static let shared = BotVaultStore()

    @Published private(set) var bots: [SavedBotAccount] = []
    @Published var activeBotId: String? {
        didSet { UserDefaults.standard.set(activeBotId, forKey: "dbc.v2.activeBotId") }
    }
    @Published var theme: BotAppearanceTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "dbc.v2.theme") }
    }
    @Published var accentHex: String {
        didSet { UserDefaults.standard.set(accentHex, forKey: "dbc.v2.accentHex") }
    }
    @Published var presenceStatus: BotPresenceStatus {
        didSet { UserDefaults.standard.set(presenceStatus.rawValue, forKey: "dbc.v2.presenceStatus") }
    }
    @Published var activityType: BotActivityType {
        didSet { UserDefaults.standard.set(activityType.rawValue, forKey: "dbc.v2.activityType") }
    }
    @Published var activityName: String {
        didSet { UserDefaults.standard.set(activityName, forKey: "dbc.v2.activityName") }
    }
    @Published var activityStreamURL: String {
        didSet { UserDefaults.standard.set(activityStreamURL, forKey: "dbc.v2.activityStreamURL") }
    }
    @Published var clientPlatform: BotClientPlatform {
        didSet { UserDefaults.standard.set(clientPlatform.rawValue, forKey: "dbc.v2.clientPlatform") }
    }
    @Published var emojiInsertAsHyperlink: Bool {
        didSet { UserDefaults.standard.set(emojiInsertAsHyperlink, forKey: "dbc.v2.emojiInsertAsHyperlink") }
    }
    @Published var buttonAutoReplies: [ButtonAutoReplyRule] {
        didSet {
            if let data = try? JSONEncoder().encode(buttonAutoReplies) {
                UserDefaults.standard.set(data, forKey: "dbc.v2.buttonAutoReplies")
            }
        }
    }
    @Published var shardIndex: Int {
        didSet { UserDefaults.standard.set(shardIndex, forKey: "dbc.v2.shardIndex") }
    }
    @Published var totalShards: Int {
        didSet { UserDefaults.standard.set(max(1, totalShards), forKey: "dbc.v2.totalShards") }
    }

    private let keychainService = "com.maniakov.discordbotclient.vault.v2"
    private let keychainAccount = "saved_bots_v2"
    private let legacyService = "com.maniakov.discordbotclient.vault"
    private let legacyAccount = "saved_bots_v1"

    static let accentPresets: [(name: String, hex: String)] = [
        ("Blurple", "#5865F2"),
        ("Emerald", "#23A55A"),
        ("Crimson", "#FA2D48"),
        ("Amber", "#F0B232"),
        ("Violet", "#8B5CF6"),
        ("Cyan", "#06B6D4")
    ]

    private init() {
        self.activeBotId = UserDefaults.standard.string(forKey: "dbc.v2.activeBotId")
        self.theme = BotAppearanceTheme(rawValue: UserDefaults.standard.string(forKey: "dbc.v2.theme") ?? "") ?? .discordDark
        self.accentHex = UserDefaults.standard.string(forKey: "dbc.v2.accentHex") ?? "#5865F2"
        self.presenceStatus = BotPresenceStatus(rawValue: UserDefaults.standard.string(forKey: "dbc.v2.presenceStatus") ?? "") ?? .online
        let rawAct = UserDefaults.standard.object(forKey: "dbc.v2.activityType") as? Int ?? 0
        self.activityType = BotActivityType(rawValue: rawAct) ?? .playing
        self.activityName = UserDefaults.standard.string(forKey: "dbc.v2.activityName") ?? ""
        self.activityStreamURL = UserDefaults.standard.string(forKey: "dbc.v2.activityStreamURL") ?? ""
        self.clientPlatform = BotClientPlatform(rawValue: UserDefaults.standard.string(forKey: "dbc.v2.clientPlatform") ?? "") ?? .discordIOS
        self.emojiInsertAsHyperlink = UserDefaults.standard.bool(forKey: "dbc.v2.emojiInsertAsHyperlink")
        if let rawRules = UserDefaults.standard.data(forKey: "dbc.v2.buttonAutoReplies"),
           let decodedRules = try? JSONDecoder().decode([ButtonAutoReplyRule].self, from: rawRules) {
            self.buttonAutoReplies = decodedRules
        } else {
            self.buttonAutoReplies = []
        }
        self.shardIndex = UserDefaults.standard.object(forKey: "dbc.v2.shardIndex") as? Int ?? 0
        self.totalShards = max(1, UserDefaults.standard.object(forKey: "dbc.v2.totalShards") as? Int ?? 1)
        self.bots = loadVault()
    }

    var activeBot: SavedBotAccount? {
        guard let activeBotId = activeBotId else { return nil }
        return bots.first(where: { $0.id == activeBotId })
    }

    var preferredColorScheme: ColorScheme { theme.colorScheme }
    var accentColor: Color { Color(hex: accentHex) }

    var backgroundColor: Color {
        switch theme {
        case .discordDark: return Color(red: 0.110, green: 0.114, blue: 0.133)
        case .midnightOLED: return Color.black
        case .light: return Color(red: 0.957, green: 0.961, blue: 0.973)
        }
    }

    var railBackgroundColor: Color {
        switch theme {
        case .discordDark: return Color(red: 0.067, green: 0.071, blue: 0.078)
        case .midnightOLED: return Color.black
        case .light: return Color(red: 0.902, green: 0.910, blue: 0.929)
        }
    }

    var surfaceColor: Color {
        switch theme {
        case .discordDark: return Color(red: 0.169, green: 0.176, blue: 0.192)
        case .midnightOLED: return Color(red: 0.078, green: 0.082, blue: 0.094)
        case .light: return Color.white
        }
    }

    var elevatedSurfaceColor: Color {
        switch theme {
        case .discordDark: return Color(red: 0.216, green: 0.227, blue: 0.247)
        case .midnightOLED: return Color(red: 0.129, green: 0.137, blue: 0.157)
        case .light: return Color(red: 0.929, green: 0.937, blue: 0.957)
        }
    }

    var primaryTextColor: Color {
        theme == .light ? Color(red: 0.08, green: 0.09, blue: 0.11) : Color.white
    }

    var secondaryTextColor: Color {
        theme == .light ? Color(red: 0.36, green: 0.39, blue: 0.44) : Color(white: 0.67)
    }

    var dividerColor: Color {
        theme == .light ? Color.black.opacity(0.08) : Color.white.opacity(0.09)
    }

    nonisolated static func normalizeToken(_ raw: String) -> String {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if (cleaned.hasPrefix("\"") && cleaned.hasSuffix("\"")) || (cleaned.hasPrefix("'") && cleaned.hasSuffix("'")) {
            cleaned = String(cleaned.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if cleaned.lowercased().hasPrefix("bot ") {
            cleaned = String(cleaned.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }

    @discardableResult
    func saveOrUpdateBot(
        token rawToken: String,
        name: String?,
        username: String?,
        id: String?,
        avatarURL: String?,
        flags: Int64? = nil,
        approximateGuildCount: Int? = nil,
        activate: Bool = true
    ) -> SavedBotAccount? {
        let cleanToken = Self.normalizeToken(rawToken)
        guard !cleanToken.isEmpty else { return nil }

        let botId = (id?.isEmpty == false ? id! : nil)
            ?? SavedBotAccount.extractIdFromToken(cleanToken)
            ?? UUID().uuidString
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (trimmedName?.isEmpty == false) ? trimmedName! : "Discord Bot \(botId.prefix(6))"

        let saved: SavedBotAccount
        if let idx = bots.firstIndex(where: { $0.id == botId || $0.token == cleanToken }) {
            bots[idx].name = displayName
            bots[idx].username = username ?? bots[idx].username
            bots[idx].avatarURL = avatarURL ?? bots[idx].avatarURL
            bots[idx].token = cleanToken
            if let flags = flags { bots[idx].flags = flags }
            if let approx = approximateGuildCount { bots[idx].approximateGuildCount = approx }
            saved = bots[idx]
        } else {
            let entry = SavedBotAccount(
                id: botId,
                name: displayName,
                username: username,
                avatarURL: avatarURL,
                token: cleanToken,
                addedAt: Date(),
                flags: flags,
                approximateGuildCount: approximateGuildCount
            )
            bots.insert(entry, at: 0)
            saved = entry
        }

        if activate {
            activeBotId = saved.id
            if let approx = saved.approximateGuildCount, approx > 2500 {
                totalShards = max(1, Int(ceil(Double(approx) / 2500.0)))
            }
        }
        persistVault(bots)
        return saved
    }

    func upsertAutoReply(customId: String, replyContent: String, ephemeral: Bool) {
        let cid = customId.trimmingCharacters(in: .whitespacesAndNewlines)
        let reply = replyContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cid.isEmpty else { return }
        if reply.isEmpty {
            buttonAutoReplies.removeAll(where: { $0.customId == cid })
            return
        }
        let rule = ButtonAutoReplyRule(customId: cid, replyContent: reply, ephemeral: ephemeral)
        if let idx = buttonAutoReplies.firstIndex(where: { $0.customId == cid }) {
            buttonAutoReplies[idx] = rule
        } else {
            buttonAutoReplies.append(rule)
        }
    }

    func renameBot(id: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = bots.firstIndex(where: { $0.id == id }) else { return }
        bots[idx].name = trimmed
        persistVault(bots)
    }

    func deleteBot(id: String) {
        bots.removeAll(where: { $0.id == id })
        if activeBotId == id {
            activeBotId = bots.first?.id
        }
        persistVault(bots)
    }

    func selectBot(id: String) {
        guard bots.contains(where: { $0.id == id }) else { return }
        shardIndex = 0
        activeBotId = id
    }

    func logout() {
        activeBotId = nil
    }

    func clearLocalCache() {
        URLCache.shared.removeAllCachedResponses()
    }

    func inviteURL(for botId: String) -> String {
        "https://discord.com/oauth2/authorize?client_id=\(botId)&permissions=274878221312&scope=bot%20applications.commands"
    }

    // MARK: - Persistent DM History & Read State

    func savedDMChannels(for botId: String) -> [DiscordChannel] {
        guard !botId.isEmpty else { return [] }
        if let url = fallbackVaultFileURL(filename: "dbc_dms_\(botId).json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([DiscordChannel].self, from: data) {
            return decoded
        }
        if let data = UserDefaults.standard.data(forKey: "dbc.v2.dms.\(botId)"),
           let decoded = try? JSONDecoder().decode([DiscordChannel].self, from: data) {
            return decoded
        }
        return []
    }

    func saveDMChannels(_ channels: [DiscordChannel], for botId: String) {
        guard !botId.isEmpty, let data = try? JSONEncoder().encode(channels) else { return }
        if let url = fallbackVaultFileURL(filename: "dbc_dms_\(botId).json") {
            try? data.write(to: url, options: .atomic)
        }
        UserDefaults.standard.set(data, forKey: "dbc.v2.dms.\(botId)")
    }

    func lastReadMessageIdByChannel(for botId: String) -> [String: String] {
        guard !botId.isEmpty else { return [:] }
        return (UserDefaults.standard.dictionary(forKey: "dbc.v2.lastRead.\(botId)") as? [String: String]) ?? [:]
    }

    func setLastReadMessageId(_ messageId: String, channelId: String, for botId: String) {
        guard !botId.isEmpty, !channelId.isEmpty, !messageId.isEmpty else { return }
        var map = lastReadMessageIdByChannel(for: botId)
        map[channelId] = messageId
        UserDefaults.standard.set(map, forKey: "dbc.v2.lastRead.\(botId)")
    }

    // MARK: - Persistence (Keychain + Application Support Fallback)

    private func fallbackVaultFileURL(filename: String = "dbc_vault_v2.json") -> URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(filename)
    }

    private func readKeychain(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess {
            return result as? Data
        }
        return nil
    }

    private func loadVault() -> [SavedBotAccount] {
        if let data = readKeychain(service: keychainService, account: keychainAccount),
           let decoded = try? JSONDecoder().decode([SavedBotAccount].self, from: data) {
            return decoded
        }
        if let fileURL = fallbackVaultFileURL(),
           let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([SavedBotAccount].self, from: data) {
            return decoded
        }
        struct LegacyEntry: Codable {
            let id: String
            var name: String
            var username: String?
            var avatarURL: String?
            var token: String
            var addedAt: Date
        }
        let legacyData = readKeychain(service: legacyService, account: legacyAccount)
            ?? fallbackVaultFileURL(filename: "dbc_vault.json").flatMap { try? Data(contentsOf: $0) }
        if let legacyData = legacyData,
           let legacy = try? JSONDecoder().decode([LegacyEntry].self, from: legacyData), !legacy.isEmpty {
            let migrated = legacy.map {
                SavedBotAccount(
                    id: $0.id,
                    name: $0.name,
                    username: $0.username,
                    avatarURL: $0.avatarURL,
                    token: $0.token,
                    addedAt: $0.addedAt,
                    flags: nil,
                    approximateGuildCount: nil
                )
            }
            persistVault(migrated)
            return migrated
        }
        return []
    }

    private func persistVault(_ entries: [SavedBotAccount]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        if status == errSecMissingEntitlement || status != errSecSuccess {
            if let fileURL = fallbackVaultFileURL() {
                try? data.write(to: fileURL, options: .atomic)
            }
        } else if let fileURL = fallbackVaultFileURL(), FileManager.default.fileExists(atPath: fileURL.path) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
