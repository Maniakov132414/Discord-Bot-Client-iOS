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
        if animated == true {
            return URL(string: "https://cdn.discordapp.com/emojis/\(id).gif?size=96")
        }
        return URL(string: "https://cdn.discordapp.com/emojis/\(id).webp?size=96&lossless=true")
    }

    var markdownString: String {
        let prefix = (animated ?? false) ? "a" : ""
        return "<\(prefix):\(name):\(id)>"
    }

    var hyperlinkMarkdown: String {
        let safeName = name.isEmpty ? "emoji" : name
        if animated == true {
            return "[\(safeName)](https://cdn.discordapp.com/emojis/\(id).gif?size=48&name=\(safeName))"
        }
        return "[\(safeName)](https://cdn.discordapp.com/emojis/\(id).webp?size=48&name=\(safeName)&lossless=true)"
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
        if animated == true {
            return URL(string: "https://cdn.discordapp.com/emojis/\(id).gif?size=96")
        }
        return URL(string: "https://cdn.discordapp.com/emojis/\(id).webp?size=96&lossless=true")
    }

    var hyperlinkMarkdown: String? {
        guard let id = id, !id.isEmpty else { return nil }
        let safeName = (name?.isEmpty == false) ? name! : "emoji"
        if animated == true {
            return "[\(safeName)](https://cdn.discordapp.com/emojis/\(id).gif?size=48&name=\(safeName))"
        }
        return "[\(safeName)](https://cdn.discordapp.com/emojis/\(id).webp?size=48&name=\(safeName)&lossless=true)"
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

    func highestRole(in guildRoles: [DiscordRole], hoistedOnly: Bool = false) -> DiscordRole? {
        let roleSet = Set(roles)
        return guildRoles
            .filter { roleSet.contains($0.id) && (!hoistedOnly || $0.hoist == true) }
            .sorted { $0.position > $1.position }
            .first
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

struct DiscordSelectOption: Codable, Equatable, Identifiable {
    var label: String
    var value: String
    var description: String?
    var isDefault: Bool?

    var id: String { value }

    enum CodingKeys: String, CodingKey {
        case label, value, description
        case isDefault = "default"
    }
}

struct DiscordUnfurledMediaItem: Codable, Equatable {
    var url: String
}

struct DiscordMediaGalleryItem: Codable, Equatable, Identifiable {
    var localId: String = UUID().uuidString
    var media: DiscordUnfurledMediaItem
    var description: String?
    var spoiler: Bool?

    var id: String { localId }

    enum CodingKeys: String, CodingKey {
        case media, description, spoiler
    }

    static func == (lhs: DiscordMediaGalleryItem, rhs: DiscordMediaGalleryItem) -> Bool {
        lhs.media == rhs.media && lhs.description == rhs.description && lhs.spoiler == rhs.spoiler
    }
}

struct DiscordComponent: Codable, Identifiable, Equatable {
    var localId: String = UUID().uuidString
    var id: String { localId }

    var type: Int
    var customId: String?
    var style: Int?
    var label: String?
    var emoji: DiscordPartialEmoji?
    var url: String?
    var disabled: Bool?
    var placeholder: String?
    var minValues: Int?
    var maxValues: Int?
    var options: [DiscordSelectOption]?
    var content: String?
    var media: DiscordUnfurledMediaItem?
    var file: DiscordUnfurledMediaItem?
    var description: String?
    var spoiler: Bool?
    var items: [DiscordMediaGalleryItem]?
    var divider: Bool?
    var spacing: Int?
    var accentColor: Int?
    var components: [DiscordComponent]?
    // Stored in a 0..1 array to prevent recursive value-type struct compile error in Swift
    private var accessoryStorage: [DiscordComponent]?

    var accessory: DiscordComponent? {
        get { accessoryStorage?.first }
        set { accessoryStorage = newValue.map { [$0] } }
    }

    init(
        type: Int,
        customId: String? = nil,
        style: Int? = nil,
        label: String? = nil,
        emoji: DiscordPartialEmoji? = nil,
        url: String? = nil,
        disabled: Bool? = nil,
        placeholder: String? = nil,
        minValues: Int? = nil,
        maxValues: Int? = nil,
        options: [DiscordSelectOption]? = nil,
        content: String? = nil,
        media: DiscordUnfurledMediaItem? = nil,
        file: DiscordUnfurledMediaItem? = nil,
        description: String? = nil,
        spoiler: Bool? = nil,
        items: [DiscordMediaGalleryItem]? = nil,
        divider: Bool? = nil,
        spacing: Int? = nil,
        accentColor: Int? = nil,
        components: [DiscordComponent]? = nil,
        accessory: DiscordComponent? = nil
    ) {
        self.type = type
        self.customId = customId
        self.style = style
        self.label = label
        self.emoji = emoji
        self.url = url
        self.disabled = disabled
        self.placeholder = placeholder
        self.minValues = minValues
        self.maxValues = maxValues
        self.options = options
        self.content = content
        self.media = media
        self.file = file
        self.description = description
        self.spoiler = spoiler
        self.items = items
        self.divider = divider
        self.spacing = spacing
        self.accentColor = accentColor
        self.components = components
        self.accessoryStorage = accessory.map { [$0] }
    }

    enum CodingKeys: String, CodingKey {
        case type, style, label, emoji, url, disabled, placeholder, options
        case content, media, file, description, spoiler, items, divider, spacing, components
        case customId = "custom_id"
        case minValues = "min_values"
        case maxValues = "max_values"
        case accentColor = "accent_color"
        case accessory = "accessory"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(Int.self, forKey: .type)
        customId = try c.decodeIfPresent(String.self, forKey: .customId)
        style = try c.decodeIfPresent(Int.self, forKey: .style)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        emoji = try c.decodeIfPresent(DiscordPartialEmoji.self, forKey: .emoji)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        disabled = try c.decodeIfPresent(Bool.self, forKey: .disabled)
        placeholder = try c.decodeIfPresent(String.self, forKey: .placeholder)
        minValues = try c.decodeIfPresent(Int.self, forKey: .minValues)
        maxValues = try c.decodeIfPresent(Int.self, forKey: .maxValues)
        options = try c.decodeIfPresent([DiscordSelectOption].self, forKey: .options)
        content = try c.decodeIfPresent(String.self, forKey: .content)
        media = try c.decodeIfPresent(DiscordUnfurledMediaItem.self, forKey: .media)
        file = try c.decodeIfPresent(DiscordUnfurledMediaItem.self, forKey: .file)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        spoiler = try c.decodeIfPresent(Bool.self, forKey: .spoiler)
        items = try c.decodeIfPresent([DiscordMediaGalleryItem].self, forKey: .items)
        divider = try c.decodeIfPresent(Bool.self, forKey: .divider)
        spacing = try c.decodeIfPresent(Int.self, forKey: .spacing)
        accentColor = try c.decodeIfPresent(Int.self, forKey: .accentColor)
        if let lossy = try? c.decodeIfPresent(LossyArray<DiscordComponent>.self, forKey: .components) {
            components = lossy.elements
        } else {
            components = nil
        }
        if let acc = try? c.decodeIfPresent(DiscordComponent.self, forKey: .accessory) {
            accessoryStorage = [acc]
        } else {
            accessoryStorage = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(customId, forKey: .customId)
        try c.encodeIfPresent(style, forKey: .style)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encodeIfPresent(emoji, forKey: .emoji)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(disabled, forKey: .disabled)
        try c.encodeIfPresent(placeholder, forKey: .placeholder)
        try c.encodeIfPresent(minValues, forKey: .minValues)
        try c.encodeIfPresent(maxValues, forKey: .maxValues)
        try c.encodeIfPresent(options, forKey: .options)
        try c.encodeIfPresent(content, forKey: .content)
        try c.encodeIfPresent(media, forKey: .media)
        try c.encodeIfPresent(file, forKey: .file)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(spoiler, forKey: .spoiler)
        try c.encodeIfPresent(items, forKey: .items)
        try c.encodeIfPresent(divider, forKey: .divider)
        try c.encodeIfPresent(spacing, forKey: .spacing)
        try c.encodeIfPresent(accentColor, forKey: .accentColor)
        try c.encodeIfPresent(components, forKey: .components)
        if let acc = accessoryStorage?.first {
            try c.encode(acc, forKey: .accessory)
        }
    }

    static func == (lhs: DiscordComponent, rhs: DiscordComponent) -> Bool {
        lhs.type == rhs.type &&
        lhs.customId == rhs.customId &&
        lhs.style == rhs.style &&
        lhs.label == rhs.label &&
        lhs.emoji == rhs.emoji &&
        lhs.url == rhs.url &&
        lhs.disabled == rhs.disabled &&
        lhs.placeholder == rhs.placeholder &&
        lhs.content == rhs.content &&
        lhs.media == rhs.media &&
        lhs.file == rhs.file &&
        lhs.description == rhs.description &&
        lhs.spoiler == rhs.spoiler &&
        lhs.items == rhs.items &&
        lhs.divider == rhs.divider &&
        lhs.spacing == rhs.spacing &&
        lhs.accentColor == rhs.accentColor &&
        lhs.components == rhs.components &&
        lhs.accessoryStorage == rhs.accessoryStorage
    }

    func toAPIDictionary() -> [String: Any]? {
        switch type {
        case 1: // ActionRow
            let children = (components ?? []).compactMap { $0.toAPIDictionary() }
            guard !children.isEmpty else { return nil }
            return ["type": 1, "components": children]

        case 2: // Button
            let st = style ?? 1
            var dict: [String: Any] = ["type": 2, "style": st]
            if let label = label, !label.isEmpty { dict["label"] = label }
            if let disabled = disabled { dict["disabled"] = disabled }
            if let emoji = emoji, (emoji.name != nil || emoji.id != nil) {
                var eDict: [String: Any] = [:]
                if let n = emoji.name { eDict["name"] = n }
                if let eid = emoji.id { eDict["id"] = eid }
                if let anim = emoji.animated { eDict["animated"] = anim }
                dict["emoji"] = eDict
            }
            if st == 5 {
                guard let u = url?.trimmingCharacters(in: .whitespacesAndNewlines), !u.isEmpty else { return nil }
                dict["url"] = u
            } else {
                let cid = (customId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                    ? customId!.trimmingCharacters(in: .whitespacesAndNewlines)
                    : "dbc_btn_\(localId.prefix(8))"
                dict["custom_id"] = cid
            }
            return dict

        case 9: // Section (must have accessory; otherwise flatten cleanly to TextDisplay 10 to prevent API 50035)
            let children = (components ?? []).compactMap { $0.toAPIDictionary() }
            guard let acc = accessory?.toAPIDictionary() else {
                let joined = (components ?? [])
                    .compactMap { $0.content }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !joined.isEmpty else { return nil }
                return ["type": 10, "content": joined]
            }
            guard !children.isEmpty else { return nil }
            return ["type": 9, "components": children, "accessory": acc]

        case 10: // TextDisplay
            let txt = content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !txt.isEmpty else { return nil }
            return ["type": 10, "content": txt]

        case 11: // Thumbnail
            guard let mUrl = media?.url.trimmingCharacters(in: .whitespacesAndNewlines), !mUrl.isEmpty else { return nil }
            var dict: [String: Any] = ["type": 11, "media": ["url": mUrl]]
            if let desc = description, !desc.isEmpty { dict["description"] = desc }
            if let sp = spoiler { dict["spoiler"] = sp }
            return dict

        case 12: // MediaGallery
            let mapped: [[String: Any]] = (items ?? []).compactMap { item in
                let u = item.media.url.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !u.isEmpty else { return nil }
                var d: [String: Any] = ["media": ["url": u]]
                if let desc = item.description, !desc.isEmpty { d["description"] = desc }
                if let sp = item.spoiler { d["spoiler"] = sp }
                return d
            }
            guard !mapped.isEmpty else { return nil }
            return ["type": 12, "items": mapped]

        case 13: // File
            guard let fUrl = file?.url.trimmingCharacters(in: .whitespacesAndNewlines), !fUrl.isEmpty else { return nil }
            var dict: [String: Any] = ["type": 13, "file": ["url": fUrl]]
            if let sp = spoiler { dict["spoiler"] = sp }
            return dict

        case 14: // Separator
            var dict: [String: Any] = ["type": 14]
            if let div = divider { dict["divider"] = div }
            if let sp = spacing { dict["spacing"] = sp }
            return dict

        case 17: // Container
            let children = (components ?? []).compactMap { $0.toAPIDictionary() }
            guard !children.isEmpty else { return nil }
            var dict: [String: Any] = ["type": 17, "components": children]
            if let ac = accentColor { dict["accent_color"] = ac }
            if let sp = spoiler { dict["spoiler"] = sp }
            return dict

        default:
            return nil
        }
    }
}

private struct EmptyDecodable: Decodable {}

struct LossyArray<Element: Decodable>: Decodable {
    let elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var out: [Element] = []
        while !container.isAtEnd {
            if let item = try? container.decode(Element.self) {
                out.append(item)
            } else {
                _ = try? container.decode(EmptyDecodable.self)
            }
        }
        self.elements = out
    }
}

struct ButtonAutoReplyRule: Codable, Identifiable, Equatable {
    var customId: String
    var replyContent: String
    var ephemeral: Bool

    var id: String { customId }
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
    var flags: Int?
    var mentionEveryone: Bool?
    var mentions: [DiscordUser]?
    var mentionRoles: [String]?
    var attachments: [DiscordAttachment] = []
    var embeds: [DiscordEmbed] = []
    var components: [DiscordComponent]?
    var reactions: [DiscordReaction]?
    var referencedMessage: DiscordReferencedMessage?
    var type: Int?

    enum CodingKeys: String, CodingKey {
        case id, author, member, content, timestamp, pinned, flags, mentions, attachments, embeds, components, reactions, type
        case channelId = "channel_id"
        case guildId = "guild_id"
        case editedTimestamp = "edited_timestamp"
        case mentionEveryone = "mention_everyone"
        case mentionRoles = "mention_roles"
        case referencedMessage = "referenced_message"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        channelId = try c.decode(String.self, forKey: .channelId)
        guildId = try c.decodeIfPresent(String.self, forKey: .guildId)
        author = try c.decode(DiscordUser.self, forKey: .author)
        member = try c.decodeIfPresent(DiscordMember.self, forKey: .member)
        content = (try? c.decodeIfPresent(String.self, forKey: .content)) ?? ""
        timestamp = try c.decode(String.self, forKey: .timestamp)
        editedTimestamp = try c.decodeIfPresent(String.self, forKey: .editedTimestamp)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned)
        flags = try c.decodeIfPresent(Int.self, forKey: .flags)
        mentionEveryone = try c.decodeIfPresent(Bool.self, forKey: .mentionEveryone)
        mentions = try c.decodeIfPresent([DiscordUser].self, forKey: .mentions)
        mentionRoles = try c.decodeIfPresent([String].self, forKey: .mentionRoles)
        attachments = (try? c.decodeIfPresent([DiscordAttachment].self, forKey: .attachments)) ?? []
        embeds = (try? c.decodeIfPresent([DiscordEmbed].self, forKey: .embeds)) ?? []
        if let lossy = try? c.decodeIfPresent(LossyArray<DiscordComponent>.self, forKey: .components) {
            components = lossy.elements
        } else {
            components = nil
        }
        reactions = try c.decodeIfPresent([DiscordReaction].self, forKey: .reactions)
        referencedMessage = try c.decodeIfPresent(DiscordReferencedMessage.self, forKey: .referencedMessage)
        type = try c.decodeIfPresent(Int.self, forKey: .type)
    }

    var isComponentsV2: Bool { ((flags ?? 0) & 32_768) != 0 }

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
    case streaming = 1
    case listening = 2
    case watching = 3
    case custom = 4
    case competing = 5

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .playing: return "Đang chơi"
        case .streaming: return "Đang phát trực tiếp"
        case .listening: return "Đang nghe"
        case .watching: return "Đang xem"
        case .custom: return "Trạng thái tùy chỉnh"
        case .competing: return "Thi đấu"
        }
    }
}

enum BotClientPlatform: String, CaseIterable, Identifiable, Codable {
    case discordIOS = "ios"
    case discordAndroid = "android"
    case desktop = "desktop"
    case web = "web"
    case embedded = "embedded"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .discordIOS: return "Điện thoại (iOS)"
        case .discordAndroid: return "Điện thoại (Android)"
        case .desktop: return "Máy tính (Windows)"
        case .web: return "Trình duyệt (Web)"
        case .embedded: return "Console (PlayStation)"
        }
    }

    var sfSymbolName: String {
        switch self {
        case .discordIOS, .discordAndroid: return "iphone"
        case .desktop: return "desktopcomputer"
        case .web: return "globe"
        case .embedded: return "gamecontroller.fill"
        }
    }

    var identifyProperties: [String: String] {
        switch self {
        case .discordIOS: return ["os": "iOS", "browser": "Discord iOS", "device": "iPhone"]
        case .discordAndroid: return ["os": "Android", "browser": "Discord Android", "device": "Android"]
        case .desktop: return ["os": "Windows", "browser": "Discord Client", "device": ""]
        case .web: return ["os": "Linux", "browser": "Chrome", "device": ""]
        case .embedded: return ["os": "Windows", "browser": "Discord Embedded", "device": "PlayStation"]
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
        return out
    }
}
