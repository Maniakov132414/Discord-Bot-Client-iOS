import Foundation
import Security
import Combine

struct SavedBotEntry: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var username: String?
    var avatarURL: String?
    var token: String
    var addedAt: Date

    var maskedToken: String {
        let clean = KeychainBotStore.normalizeToken(token)
        guard clean.count > 10 else { return "••••••••" }
        return "\(clean.prefix(6))••••\(clean.suffix(4))"
    }
}

enum ConnectionMode: String, CaseIterable, Identifiable, Codable {
    case standalone = "standalone"
    case customServer = "custom"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standalone: return "Độc lập trên máy (Khuyên dùng)"
        case .customServer: return "Server Web tùy chỉnh (URL)"
        }
    }
}

@MainActor
final class KeychainBotStore: ObservableObject {
    static let shared = KeychainBotStore()

    @Published private(set) var bots: [SavedBotEntry] = []
    @Published var activeBotId: String? {
        didSet { UserDefaults.standard.set(activeBotId, forKey: "dbc.activeBotId") }
    }
    @Published var connectionMode: ConnectionMode {
        didSet { UserDefaults.standard.set(connectionMode.rawValue, forKey: "dbc.connectionMode") }
    }
    @Published var customServerURL: String {
        didSet { UserDefaults.standard.set(customServerURL, forKey: "dbc.customServerURL") }
    }

    private let keychainService = "com.maniakov.discordbotclient.vault"
    private let keychainAccount = "saved_bots_v1"

    private init() {
        self.activeBotId = UserDefaults.standard.string(forKey: "dbc.activeBotId")
        self.connectionMode = ConnectionMode(rawValue: UserDefaults.standard.string(forKey: "dbc.connectionMode") ?? "") ?? .standalone
        self.customServerURL = UserDefaults.standard.string(forKey: "dbc.customServerURL") ?? ""
        self.bots = loadVaultFromKeychain()
    }

    static func normalizeToken(_ raw: String) -> String {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if (cleaned.hasPrefix("\"") && cleaned.hasSuffix("\"")) || (cleaned.hasPrefix("'") && cleaned.hasSuffix("'")) {
            cleaned = String(cleaned.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if cleaned.lowercased().hasPrefix("bot ") {
            cleaned = String(cleaned.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }

    func saveOrUpdateBot(token rawToken: String, name: String?, username: String?, id: String?, avatarURL: String?) {
        let cleanToken = Self.normalizeToken(rawToken)
        guard !cleanToken.isEmpty else { return }

        let botId = (id?.isEmpty == false ? id! : nil) ?? extractIdFromToken(cleanToken) ?? UUID().uuidString
        let displayName = (name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? name!.trimmingCharacters(in: .whitespacesAndNewlines)
            : "Discord Bot \(botId.prefix(6))"

        if let idx = bots.firstIndex(where: { $0.id == botId || $0.token == cleanToken }) {
            bots[idx].name = displayName
            bots[idx].username = username ?? bots[idx].username
            bots[idx].avatarURL = avatarURL ?? bots[idx].avatarURL
            bots[idx].token = cleanToken
            activeBotId = bots[idx].id
        } else {
            let entry = SavedBotEntry(
                id: botId,
                name: displayName,
                username: username,
                avatarURL: avatarURL,
                token: cleanToken,
                addedAt: Date()
            )
            bots.insert(entry, at: 0)
            activeBotId = entry.id
        }
        persistVaultToKeychain(bots)
    }

    func deleteBot(id: String) {
        bots.removeAll(where: { $0.id == id })
        if activeBotId == id {
            activeBotId = bots.first?.id
        }
        persistVaultToKeychain(bots)
    }

    func clearActiveTokenSelection() {
        activeBotId = nil
    }

    var activeBot: SavedBotEntry? {
        guard let activeBotId = activeBotId else { return nil }
        return bots.first(where: { $0.id == activeBotId })
    }

    private func extractIdFromToken(_ token: String) -> String? {
        guard let first = token.split(separator: ".").first else { return nil }
        var b64 = String(first)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let str = String(data: data, encoding: .utf8),
              !str.isEmpty,
              str.allSatisfy(\.isNumber) else {
            return nil
        }
        return str
    }

    private func loadVaultFromKeychain() -> [SavedBotEntry] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data,
           let decoded = try? JSONDecoder().decode([SavedBotEntry].self, from: data) {
            return decoded
        }
        return []
    }

    private func persistVaultToKeychain(_ entries: [SavedBotEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }
}
