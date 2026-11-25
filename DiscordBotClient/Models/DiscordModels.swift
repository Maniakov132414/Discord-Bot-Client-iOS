import Foundation
import SwiftUI

struct DiscordUser: Codable, Identifiable, Equatable {
    let id: String
    var username: String
    var globalName: String?
    var discriminator: String?
    var avatar: String?
    var bot: Bool?
    var system: Bool?
    var publicFlags: Int?
    var banner: String?
    var accentColor: Int?

    enum CodingKeys: String, CodingKey {
        case id, username, discriminator, avatar, bot, system, banner
        case globalName = "global_name"
        case publicFlags = "public_flags"
        case accentColor = "accent_color"
    }

    var displayName: String {
        if let gn = globalName, !gn.isEmpty { return gn }
        return username
    }

    func avatarURL(size: Int = 128) -> URL? {
        if let hash = avatar, !hash.isEmpty {
            let ext = hash.hasPrefix("a_") ? "gif" : "png"
            return URL(string: "https://cdn.discordapp.com/avatars/\(id)/\(hash).\(ext)?size=\(size)")
        }
        let idx: Int
        if let disc = discriminator, disc != "0", let d = Int(disc) {
            idx = d % 5
        } else {
            idx = Int((UInt64(id) ?? 0) >> 22) % 6
        }
        return URL(string: "https://cdn.discordapp.com/embed/avatars/\(idx).png")
    }
}

struct DiscordApplication: Codable, Identifiable {
    let id: String
    var name: String?
    var icon: String?
    var description: String?
    var flags: Int64?
    var approximateGuildCount: Int?
    var bot: DiscordUser?

    enum CodingKeys: String, CodingKey {
        case id, name, icon, description, flags, bot
        case approximateGuildCount = "approximate_guild_count"
    }

    var iconURL: URL? {
        guard let icon = icon, !icon.isEmpty else { return nil }
        return URL(string: "https://cdn.discordapp.com/app-icons/\(id)/\(icon).png?size=256")
    }

    func inviteURL(permissions: String = "274878221312") -> URL? {
        URL(string: "https://discord.com/oauth2/authorize?client_id=\(id)&permissions=\(permissions)&scope=bot%20applications.commands")
    }
}

struct DiscordRole: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var color: Int
    var position: Int
    var hoist: Bool?
    var managed: Bool?

    var swiftUIColor: Color? {
        guard color != 0 else { return nil }
        return Color(
            red: Double((color >> 16) & 0xFF) / 255.0,
            green: Double((color >> 8) & 0xFF) / 255.0,
            blue: Double(color & 0xFF) / 255.0
        )
    }
}

struct DiscordEmoji: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var animated: Bool?
    var available: Bool?

    var imageURL: URL? {
        let ext = (animated ?? false) ? "gif" : "png"
        return URL(string: "https://cdn.discordapp.com/emojis/\(id).\(ext)?size=96")
    }

    var markdownString: String {
        let prefix = (animated ?? false) ? "a" : ""
        return "<\(prefix):\(name):\(id)>"
    }

    var apiIdentifier: String {
        "\(name):\(id)"
    }
}

struct DiscordPartialEmoji: Codable, Equatable, Hashable {
    var id: String?
    var name: String?
    var animated: Bool?

    var imageURL: URL? {
        guard let id = id, !id.isEmpty else { return nil }
        let ext = (animated ?? false) ? "gif" : "png"
        return URL(string: "https://cdn.discordapp.com/emojis/\(id).\(ext)?size=64")
    }

    var apiIdentifier: String {
        if let id = id, !id.isEmpty, let name = name {
            return "\(name):\(id)"
        }
        return name ?? ""
    }

    var displayLabel: String {
        if id != nil {
            return ":\(name ?? "emoji"):"
        }
        return name ?? "?"
    }
}

struct DiscordChannel: Codable, Identifiable, Equatable {
    let id: String
    var type: Int
    var guildId: String?
    var name: String?
    var topic: String?
    var position: Int?
    var parentId: String?
    var lastMessageId: String?
    var nsfw: Bool?
    var recipients: [DiscordUser]?

    enum CodingKeys: String, CodingKey {
        case id, type, name, topic, position, nsfw, recipients
        case guildId = "guild_id"
        case parentId = "parent_id"
        case lastMessageId = "last_message_id"
    }

    var isCategory: Bool { type == 4 }
    var isVoice: Bool { type == 2 || type == 13 }
    var isTextSendable: Bool { [0, 5, 10, 11, 12, 1].contains(type) }

    var displayName: String {
        if let n = name, !n.isEmpty { return n }
        if let r = recipients?.first { return r.displayName }
        return "channel-\(id.suffix(4))"
    }

    var sfSymbolName: String {
        switch type {
        case 2, 13: return "speaker.wave.2"
        case 4: return "folder"
        case 5: return "megaphone"
        case 10, 11, 12: return "text.bubble"
        case 15: return "bubble.left.and.bubble.right"
        case 1, 3: return "person.crop.circle"
        default: return "number"
        }
    }
}

struct DiscordGuild: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var icon: String?
    var ownerId: String?
    var memberCount: Int?
    var channels: [DiscordChannel] = []
    var roles: [DiscordRole] = []
    var emojis: [DiscordEmoji] = []

    enum CodingKeys: String, CodingKey {
        case id, name, icon, channels, roles, emojis
        case ownerId = "owner_id"
        case memberCount = "member_count"
    }

    var iconURL: URL? {
        guard let icon = icon, !icon.isEmpty else { return nil }
        let ext = icon.hasPrefix("a_") ? "gif" : "png"
        return URL(string: "https://cdn.discordapp.com/icons/\(id)/\(icon).\(ext)?size=128")
    }

    var initials: String {
        let words = name.split(separator: " ").prefix(2)
        let joined = words.compactMap { $0.first.map(String.init) }.joined()
        return joined.isEmpty ? String(name.prefix(2)).uppercased() : joined.uppercased()
    }
}

struct DiscordMember: Codable, Identifiable, Equatable {
    var user: DiscordUser?
    var nick: String?
    var roles: [String] = []
    var avatar: String?
    var joinedAt: String?

    var id: String { user?.id ?? UUID().uuidString }

    enum CodingKeys: String, CodingKey {
        case user, nick, roles, avatar
        case joinedAt = "joined_at"
    }

    func displayName(fallback: String? = nil) -> String {
        if let nick = nick, !nick.isEmpty { return nick }
        if let u = user { return u.displayName }
        return fallback ?? "Unknown"
    }

    func highestRoleColor(in guildRoles: [DiscordRole]) -> Color? {
        let roleSet = Set(roles)
        let matching = guildRoles
            .filter { roleSet.contains($0.id) && $0.color != 0 }
            .sorted { $0.position > $1.position }
        return matching.first?.swiftUIColor
    }

    func avatarURL(guildId: String?, size: Int = 128) -> URL? {
        if let gId = guildId, let uid = user?.id, let mAvatar = avatar, !mAvatar.isEmpty {
            let ext = mAvatar.hasPrefix("a_") ? "gif" : "png"
            return URL(string: "https://cdn.discordapp.com/guilds/\(gId)/users/\(uid)/avatars/\(mAvatar).\(ext)?size=\(size)")
        }
        return user?.avatarURL(size: size)
    }
}

struct DiscordAttachment: Codable, Identifiable, Equatable {
    let id: String
    var filename: String
    var size: Int
    var url: String
    var proxyUrl: String?
    var contentType: String?
    var width: Int?
    var height: Int?

    enum CodingKeys: String, CodingKey {
        case id, filename, size, url, width, height
        case proxyUrl = "proxy_url"
        case contentType = "content_type"
    }

    var isImage: Bool {
        if let ct = contentType?.lowercased(), ct.hasPrefix("image/") { return true }
        let ext = (filename as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(ext)
    }

    var isVideo: Bool {
        if let ct = contentType?.lowercased(), ct.hasPrefix("video/") { return true }
        let ext = (filename as NSString).pathExtension.lowercased()
        return ["mp4", "mov", "m4v", "webm"].contains(ext)
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

struct DiscordEmbedFooter: Codable, Equatable {
    var text: String
    var iconUrl: String?

    enum CodingKeys: String, CodingKey {
        case text
        case iconUrl = "icon_url"
    }
}

struct DiscordEmbedMedia: Codable, Equatable {
    var url: String
}

struct DiscordEmbedAuthor: Codable, Equatable {
    var name: String
    var url: String?
    var iconUrl: String?

    enum CodingKeys: String, CodingKey {
        case name, url
        case iconUrl = "icon_url"
    }
}

struct DiscordEmbedField: Codable, Equatable, Identifiable {
    var id: String { "\(name)-\(value)" }
    var name: String
    var value: String
    var inline: Bool?
}

struct DiscordEmbed: Codable, Equatable, Identifiable {
    var id: String { "\(title ?? "")-\(description ?? "")-\(url ?? "")" }
    var title: String?
    var description: String?
    var url: String?
    var color: Int?
    var timestamp: String?
    var footer: DiscordEmbedFooter?
    var image: DiscordEmbedMedia?
    var thumbnail: DiscordEmbedMedia?
    var author: DiscordEmbedAuthor?
    var fields: [DiscordEmbedField]?

    var accentColor: Color {
        guard let color = color, color != 0 else {
            return Color(red: 0.345, green: 0.396, blue: 0.949)
        }
        return Color(
            red: Double((color >> 16) & 0xFF) / 255.0,
            green: Double((color >> 8) & 0xFF) / 255.0,
            blue: Double(color & 0xFF) / 255.0
        )
    }
}

struct DiscordReaction: Codable, Equatable, Identifiable {
    var count: Int
    var me: Bool
    var emoji: DiscordPartialEmoji

    var id: String { emoji.apiIdentifier }
}

struct DiscordReferencedMessage: Codable, Equatable {
    let id: String
    var channelId: String?
    var author: DiscordUser?
    var content: String?
    var attachments: [DiscordAttachment]?
    var embeds: [DiscordEmbed]?

    enum CodingKeys: String, CodingKey {
        case id, author, content, attachments, embeds
        case channelId = "channel_id"
    }
}

struct DiscordMessage: Codable, Identifiable, Equatable {
    let id: String
    var channelId: String
    var guildId: String?
    var author: DiscordUser
    var member: DiscordMember?
    var content: String
    var timestamp: String
    var editedTimestamp: String?
    var pinned: Bool?
    var mentionEveryone: Bool?
    var mentions: [DiscordUser]?
    var mentionRoles: [String]?
    var attachments: [DiscordAttachment] = []
    var embeds: [DiscordEmbed] = []
    var reactions: [DiscordReaction]?
    var referencedMessage: DiscordReferencedMessage?
    var type: Int?

    enum CodingKeys: String, CodingKey {
        case id, author, member, content, timestamp, pinned, mentions, attachments, embeds, reactions, type
        case channelId = "channel_id"
        case guildId = "guild_id"
        case editedTimestamp = "edited_timestamp"
        case mentionEveryone = "mention_everyone"
        case mentionRoles = "mention_roles"
        case referencedMessage = "referenced_message"
    }

    var parsedTimestamp: Date? {
        DiscordDateParser.parse(timestamp)
    }
}

enum DiscordDateParser {
    private static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    private static let dayTimeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd/MM HH:mm"
        return f
    }()

    static func parse(_ raw: String?) -> Date? {
        guard let raw = raw, !raw.isEmpty else { return nil }
        return withFractional.date(from: raw) ?? plain.date(from: raw)
    }

    static func formatShort(_ raw: String?) -> String {
        guard let d = parse(raw) else { return "" }
        if Calendar.current.isDateInToday(d) {
            return timeFmt.string(from: d)
        }
        return dayTimeFmt.string(from: d)
    }
}

struct SavedBotAccount: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var username: String?
    var avatarURL: String?
    var token: String
    var addedAt: Date
    var flags: Int64?
    var approximateGuildCount: Int?

    var maskedToken: String {
        let clean = BotVaultStore.normalizeToken(token)
        guard clean.count > 10 else { return "••••••••" }
        return "\(clean.prefix(6))••••\(clean.suffix(4))"
    }

    static func extractIdFromToken(_ token: String) -> String? {
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
}

enum BotAppearanceTheme: String, CaseIterable, Identifiable, Codable {
    case discordDark = "discordDark"
    case midnightOLED = "midnightOLED"
    case light = "light"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .discordDark: return "Discord Dark"
        case .midnightOLED: return "Midnight OLED"
        case .light: return "Light"
        }
    }

    var colorScheme: ColorScheme {
        self == .light ? .light : .dark
    }
}

enum BotPresenceStatus: String, CaseIterable, Identifiable, Codable {
    case online = "online"
    case idle = "idle"
    case dnd = "dnd"
    case invisible = "invisible"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .online: return "Trực tuyến"
        case .idle: return "Chờ"
        case .dnd: return "Không làm phiền"
        case .invisible: return "Ẩn"
        }
    }

    var dotColor: Color {
        switch self {
        case .online: return Color(red: 0.137, green: 0.647, blue: 0.353)
        case .idle: return Color(red: 0.941, green: 0.698, blue: 0.196)
        case .dnd: return Color(red: 0.949, green: 0.247, blue: 0.259)
        case .invisible: return Color.gray
        }
    }
}

enum BotActivityType: Int, CaseIterable, Identifiable, Codable {
    case playing = 0
    case listening = 2
    case watching = 3
    case competing = 5

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .playing: return "Đang chơi"
        case .listening: return "Đang nghe"
        case .watching: return "Đang xem"
        case .competing: return "Thi đấu"
        }
    }
}

struct MediaUploadItem: Identifiable {
    let id = UUID()
    let filename: String
    let mimeType: String
    let data: Data
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&int)
        let r, g, b: UInt64
        switch cleaned.count {
        case 6:
            (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (r, g, b) = (88, 101, 242)
        }
        self.init(.sRGB, red: Double(r) / 255.0, green: Double(g) / 255.0, blue: Double(b) / 255.0, opacity: 1.0)
    }

    func toHexString() -> String {
        let ui = UIColor(self)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
    }
}

enum DiscordTextFormatter {
    static func renderCleanText(
        _ raw: String,
        guild: DiscordGuild?,
        mentions: [DiscordUser]?,
        members: [DiscordMember]
    ) -> String {
        var out = raw
        // <@!id> or <@id>
        if let regex = try? NSRegularExpression(pattern: #"<@!?(\d+)>"#) {
            let matches = regex.matches(in: out, range: NSRange(out.startIndex..., in: out))
            for m in matches.reversed() {
                guard let full = Range(m.range, in: out),
                      let idRange = Range(m.range(at: 1), in: out) else { continue }
                let uid = String(out[idRange])
                let name = members.first(where: { $0.user?.id == uid })?.displayName()
                    ?? mentions?.first(where: { $0.id == uid })?.displayName
                    ?? "user-\(uid.suffix(4))"
                out.replaceSubrange(full, with: "@\(name)")
            }
        }
        // <@&roleId>
        if let regex = try? NSRegularExpression(pattern: #"<@&(\d+)>"#) {
            let matches = regex.matches(in: out, range: NSRange(out.startIndex..., in: out))
            for m in matches.reversed() {
                guard let full = Range(m.range, in: out),
                      let idRange = Range(m.range(at: 1), in: out) else { continue }
                let rid = String(out[idRange])
                let rname = guild?.roles.first(where: { $0.id == rid })?.name ?? "role"
                out.replaceSubrange(full, with: "@\(rname)")
            }
        }
        // <#channelId>
        if let regex = try? NSRegularExpression(pattern: #"<#(\d+)>"#) {
            let matches = regex.matches(in: out, range: NSRange(out.startIndex..., in: out))
            for m in matches.reversed() {
                guard let full = Range(m.range, in: out),
                      let idRange = Range(m.range(at: 1), in: out) else { continue }
                let cid = String(out[idRange])
                let cname = guild?.channels.first(where: { $0.id == cid })?.displayName ?? "channel"
                out.replaceSubrange(full, with: "#\(cname)")
            }
        }
        // <:name:id> or <a:name:id>
        if let regex = try? NSRegularExpression(pattern: #"<a?:([A-Za-z0-9_]+):(\d+)>"#) {
            let matches = regex.matches(in: out, range: NSRange(out.startIndex..., in: out))
            for m in matches.reversed() {
                guard let full = Range(m.range, in: out),
                      let nameRange = Range(m.range(at: 1), in: out) else { continue }
                out.replaceSubrange(full, with: ":\(out[nameRange]):")
            }
        }
        return out
    }
}
