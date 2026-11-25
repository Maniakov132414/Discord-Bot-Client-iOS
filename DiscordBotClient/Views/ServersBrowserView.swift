import SwiftUI

struct ServersBrowserView: View {
    @EnvironmentObject private var vault: BotVaultStore
    @EnvironmentObject private var gateway: DiscordGatewayService

    @State private var channelSearch: String = ""
    @State private var collapsedCategoryIds: Set<String> = []
    @State private var activeChatChannel: DiscordChannel?
    @State private var pushChat = false

    private var selectedGuild: DiscordGuild? {
        if let gid = gateway.selectedGuildId, let g = gateway.guilds.first(where: { $0.id == gid }) {
            return g
        }
        return gateway.guilds.first
    }

    var body: some View {
        NavigationView {
            ZStack {
                vault.backgroundColor.ignoresSafeArea()

                if let channel = activeChatChannel {
                    NavigationLink(
                        destination: ChannelChatView(channel: channel, guild: selectedGuild),
                        isActive: $pushChat
                    ) {
                        EmptyView()
                    }
                    .hidden()
                }

                if gateway.guilds.isEmpty {
                    VStack(spacing: 14) {
                        if gateway.connectionState == .connecting || gateway.connectionState == .reconnecting {
                            ProgressView()
                                .tint(vault.accentColor)
                            Text("Đang đồng bộ danh sách máy chủ...")
                                .font(.subheadline)
                                .foregroundColor(vault.secondaryTextColor)
                        } else {
                            Image(systemName: "server.rack")
                                .font(.system(size: 38))
                                .foregroundColor(vault.secondaryTextColor)
                            Text("Bot chưa tham gia máy chủ nào")
                                .font(.headline)
                                .foregroundColor(vault.primaryTextColor)
                            Text("Vào tab Tài khoản để sao chép link mời Bot.")
                                .font(.caption)
                                .foregroundColor(vault.secondaryTextColor)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HStack(spacing: 0) {
                        serverRail
                        Divider().background(vault.dividerColor)
                        channelListPane
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(gateway.connectionState.color)
                            .frame(width: 8, height: 8)
                        Text(selectedGuild?.name ?? "Máy chủ")
                            .font(.headline)
                            .foregroundColor(vault.primaryTextColor)
                            .lineLimit(1)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await gateway.reconnectIfNeeded(vault: vault) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.subheadline)
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - 68pt Server Icon Rail

    private var serverRail: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 10) {
                ForEach(gateway.guilds) { guild in
                    let isSelected = selectedGuild?.id == guild.id
                    Button {
                        gateway.selectedGuildId = guild.id
                        Task { await gateway.refreshGuildDetailsIfNeeded(guild.id) }
                    } label: {
                        HStack(spacing: 0) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.white)
                                .frame(width: 4, height: isSelected ? 32 : 0)
                                .opacity(isSelected ? 1 : 0)

                            Spacer(minLength: 4)

                            guildIconView(guild: guild, isSelected: isSelected)
                                .frame(width: 48, height: 48)

                            Spacer(minLength: 6)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 10)
        }
        .frame(width: 68)
        .background(vault.railBackgroundColor)
    }

    private func guildIconView(guild: DiscordGuild, isSelected: Bool) -> some View {
        let corner: CGFloat = isSelected ? 15 : 24
        return Group {
            if let url = guild.iconURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    default:
                        guildInitialsView(guild: guild, isSelected: isSelected)
                    }
                }
            } else {
                guildInitialsView(guild: guild, isSelected: isSelected)
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(isSelected ? vault.accentColor : Color.clear, lineWidth: 2)
        )
    }

    private func guildInitialsView(guild: DiscordGuild, isSelected: Bool) -> some View {
        ZStack {
            (isSelected ? vault.accentColor : vault.surfaceColor)
            Text(guild.initials)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(isSelected ? .white : vault.primaryTextColor)
        }
    }

    // MARK: - Categorized Channel List

    private var channelListPane: some View {
        VStack(spacing: 0) {
            if let guild = selectedGuild {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(guild.name)
                                .font(.subheadline.weight(.bold))
                                .foregroundColor(vault.primaryTextColor)
                                .lineLimit(1)
                            if let mc = guild.memberCount {
                                Text("\(mc) thành viên • \(guild.channels.count) kênh")
                                    .font(.caption2)
                                    .foregroundColor(vault.secondaryTextColor)
                            }
                        }
                        Spacer()
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.caption)
                            .foregroundColor(vault.secondaryTextColor)
                        TextField("Tìm kênh...", text: $channelSearch)
                            .font(.subheadline)
                            .textFieldStyle(.plain)
                        if !channelSearch.isEmpty {
                            Button {
                                channelSearch = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundColor(vault.secondaryTextColor)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(vault.elevatedSurfaceColor)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .padding(12)
                .background(vault.surfaceColor.opacity(0.6))

                Divider().background(vault.dividerColor)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        let grouped = groupedChannels(for: guild)
                        ForEach(grouped.uncategorized) { ch in
                            channelRow(ch, guild: guild)
                        }
                        ForEach(grouped.categories, id: \.category.id) { section in
                            categoryHeader(section.category)
                            if !collapsedCategoryIds.contains(section.category.id) || !channelSearch.isEmpty {
                                ForEach(section.channels) { ch in
                                    channelRow(ch, guild: guild)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(vault.backgroundColor)
    }

    private func categoryHeader(_ cat: DiscordChannel) -> some View {
        let isCollapsed = collapsedCategoryIds.contains(cat.id)
        return Button {
            if isCollapsed {
                collapsedCategoryIds.remove(cat.id)
            } else {
                collapsedCategoryIds.insert(cat.id)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                Text(cat.displayName.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .lineLimit(1)
                Spacer()
            }
            .foregroundColor(vault.secondaryTextColor)
            .padding(.horizontal, 6)
            .padding(.top, 10)
            .padding(.bottom, 4)
        }
        .buttonStyle(.plain)
    }

    private func channelRow(_ ch: DiscordChannel, guild: DiscordGuild) -> some View {
        let isSelected = gateway.selectedChannelId == ch.id
        return Button {
            guard !ch.isVoice else { return }
            gateway.selectedChannelId = ch.id
            activeChatChannel = ch
            pushChat = true
            Task { await gateway.refreshGuildDetailsIfNeeded(guild.id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: ch.sfSymbolName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(isSelected ? vault.primaryTextColor : vault.secondaryTextColor)
                    .frame(width: 20)

                Text(ch.displayName)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .foregroundColor(ch.isVoice ? vault.secondaryTextColor.opacity(0.6) : (isSelected ? vault.primaryTextColor : vault.primaryTextColor.opacity(0.88)))
                    .lineLimit(1)

                Spacer()

                if !ch.isVoice {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11))
                        .foregroundColor(vault.secondaryTextColor.opacity(0.5))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(isSelected ? vault.elevatedSurfaceColor : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func groupedChannels(for guild: DiscordGuild) -> (uncategorized: [DiscordChannel], categories: [(category: DiscordChannel, channels: [DiscordChannel])]) {
        let q = channelSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let categories = guild.channels
            .filter { $0.isCategory }
            .sorted { ($0.position ?? 0) < ($1.position ?? 0) }
        let nonCats = guild.channels
            .filter { !$0.isCategory && (q.isEmpty || $0.displayName.lowercased().contains(q)) }
            .sorted { ($0.position ?? 0) < ($1.position ?? 0) }

        let catIds = Set(categories.map(\.id))
        let uncategorized = nonCats.filter { ch in
            guard let pid = ch.parentId else { return true }
            return !catIds.contains(pid)
        }
        let sections: [(category: DiscordChannel, channels: [DiscordChannel])] = categories.compactMap { cat in
            let children = nonCats.filter { $0.parentId == cat.id }
            if !q.isEmpty && children.isEmpty { return nil }
            return (category: cat, channels: children)
        }
        return (uncategorized, sections)
    }
}
