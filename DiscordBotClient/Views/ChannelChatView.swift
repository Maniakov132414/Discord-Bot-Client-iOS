import SwiftUI
import UIKit

struct ChannelChatView: View {
    let channel: DiscordChannel
    let guild: DiscordGuild?

    @EnvironmentObject private var vault: BotVaultStore
    @EnvironmentObject private var gateway: DiscordGatewayService

    @State private var composerText: String = ""
    @State private var pendingAttachments: [MediaUploadItem] = []
    @State private var pendingEmbeds: [DiscordEmbed] = []
    @State private var pendingComponents: [DiscordComponent] = []
    @State private var replyTarget: DiscordMessage?
    @State private var editingTarget: DiscordMessage?
    @State private var isSending = false
    @State private var sendError: String?

    @State private var showPhotoPicker = false
    @State private var showDocumentPicker = false
    @State private var showEmojiPicker = false
    @State private var showMessageStudio = false
    @State private var editingEmbedTarget: DiscordMessage?
    @State private var reactionTarget: DiscordMessage?
    @State private var showMembersSheet = false
    @State private var inspectedMember: DiscordMember?
    @State private var showPinsSheet = false
    @State private var showPurgeSheet = false
    @State private var previewImageItem: IdentifiableURL?
    @State private var previewVideoItem: IdentifiableURL?
    @State private var pushedDMChannel: DiscordChannel?
    @State private var pushDM = false

    private var messages: [DiscordMessage] {
        gateway.messagesByChannel[channel.id] ?? []
    }

    private var members: [DiscordMember] {
        guard let gid = guild?.id ?? channel.guildId else { return [] }
        return gateway.membersByGuild[gid] ?? []
    }

    private var typingUsers: [String] {
        let now = Date()
        return (gateway.typingUsersByChannel[channel.id] ?? [:])
            .filter { $0.value > now }
            .keys
            .sorted()
    }

    var body: some View {
        ZStack {
            if let dm = pushedDMChannel {
                NavigationLink(
                    destination: ChannelChatView(channel: dm, guild: nil),
                    isActive: $pushDM
                ) {
                    EmptyView()
                }
                .hidden()
            }

            VStack(spacing: 0) {
                timelineView
                typingBar
                autocompleteBar
                composerContainer
            }
        }
        .background(vault.backgroundColor.ignoresSafeArea())
        .navigationTitle(channel.type == 1 || channel.type == 3 ? channel.displayName : "#\(channel.displayName)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    showPinsSheet = true
                } label: {
                    Image(systemName: "pin")
                }

                if guild != nil {
                    Button {
                        showMembersSheet = true
                    } label: {
                        Image(systemName: "person.2")
                    }
                }

                Button {
                    showPurgeSheet = true
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .task(id: channel.id) {
            await gateway.loadMessages(channelId: channel.id)
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoPickerSheet { items in
                pendingAttachments.append(contentsOf: items)
            }
        }
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPickerSheet { items in
                pendingAttachments.append(contentsOf: items)
            }
        }
        .sheet(isPresented: $showEmojiPicker) {
            EmojiPickerSheet(currentGuild: guild) { snippet in
                composerText += snippet
            }
            .environmentObject(vault)
            .environmentObject(gateway)
        }
        .sheet(isPresented: $showMessageStudio) {
            MessageStudioSheet(
                initialEmbed: nil,
                onAttachV1: { emb, comps in
                    if let emb = emb { pendingEmbeds.append(emb) }
                    if !comps.isEmpty { pendingComponents.append(contentsOf: comps) }
                },
                onSendV2: { comps, flags in
                    try await gateway.sendMessage(
                        channelId: channel.id,
                        content: "",
                        embeds: [],
                        components: comps,
                        flags: flags
                    )
                }
            )
            .environmentObject(vault)
            .environmentObject(gateway)
        }
        .sheet(item: $editingEmbedTarget) { msg in
            MessageStudioSheet(
                initialEmbed: msg.embeds.first,
                onAttachV1: { updatedEmbed, comps in
                    Task {
                        try? await gateway.editMessage(
                            channelId: channel.id,
                            messageId: msg.id,
                            content: msg.content,
                            embeds: updatedEmbed.map { [$0] } ?? msg.embeds,
                            components: comps.isEmpty ? msg.components : comps
                        )
                    }
                },
                onSendV2: { comps, flags in
                    try await gateway.editMessage(
                        channelId: channel.id,
                        messageId: msg.id,
                        content: nil,
                        embeds: nil,
                        components: comps,
                        flags: flags
                    )
                }
            )
            .environmentObject(vault)
        }
        .sheet(item: $reactionTarget) { msg in
            ReactionPickerSheet(
                currentGuild: guild,
                existingReactions: msg.reactions ?? []
            ) { emojiIdentifier, alreadyMine in
                Task {
                    await gateway.toggleReaction(
                        channelId: channel.id,
                        messageId: msg.id,
                        emojiIdentifier: emojiIdentifier,
                        currentlyMine: alreadyMine
                    )
                }
            }
            .environmentObject(vault)
            .environmentObject(gateway)
        }
        .sheet(isPresented: $showMembersSheet) {
            if let gid = guild?.id ?? channel.guildId {
                MembersDrawerSheet(
                    guildId: gid,
                    guild: guild,
                    roles: guild?.roles ?? [],
                    onMention: { member in
                        if let uid = member.user?.id {
                            composerText += " <@\(uid)> "
                        }
                    },
                    onOpenDMChannel: { dm in
                        pushedDMChannel = dm
                        pushDM = true
                    }
                )
                .environmentObject(vault)
                .environmentObject(gateway)
            }
        }
        .sheet(item: $inspectedMember) { member in
            MemberProfileSheet(
                member: member,
                guildId: guild?.id ?? channel.guildId,
                roles: guild?.roles ?? [],
                onMention: { m in
                    if let uid = m.user?.id {
                        composerText += " <@\(uid)> "
                    }
                },
                onOpenDMChannel: { dm in
                    pushedDMChannel = dm
                    pushDM = true
                }
            )
            .environmentObject(vault)
            .environmentObject(gateway)
        }
        .sheet(isPresented: $showPinsSheet) {
            PinnedMessagesSheet(channelId: channel.id, guild: guild, members: members)
        }
        .sheet(isPresented: $showPurgeSheet) {
            PurgeMessagesSheet(channelId: channel.id)
        }
        .sheet(item: $previewImageItem) { item in
            ImageViewerSheet(url: item.url, filename: item.title)
        }
        .sheet(item: $previewVideoItem) { item in
            VideoPlayerSheet(url: item.url, filename: item.title)
        }
    }

    // MARK: - Message Timeline

    private var timelineView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if gateway.hasMoreOlderByChannel[channel.id] == true {
                        Button {
                            Task { await gateway.loadOlderMessages(channelId: channel.id) }
                        } label: {
                            HStack(spacing: 6) {
                                if gateway.loadingChannelIds.contains(channel.id) {
                                    ProgressView().scaleEffect(0.75)
                                } else {
                                    Image(systemName: "arrow.up.circle")
                                }
                                Text("Tải tin nhắn cũ hơn")
                                    .font(.caption.weight(.semibold))
                            }
                            .foregroundColor(vault.accentColor)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                    }

                    ForEach(Array(messages.enumerated()), id: \.element.id) { idx, msg in
                        let prev = idx > 0 ? messages[idx - 1] : nil
                        let grouped = isGroupedWithPrevious(msg, previous: prev)
                        messageRow(msg, grouped: grouped)
                            .id(msg.id)
                    }

                    Color.clear
                        .frame(height: 6)
                        .id("bottom-anchor")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: messages.last?.id) { _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom-anchor", anchor: .bottom)
                }
            }
            .onAppear {
                proxy.scrollTo("bottom-anchor", anchor: .bottom)
            }
        }
    }

    private func isGroupedWithPrevious(_ msg: DiscordMessage, previous: DiscordMessage?) -> Bool {
        guard let prev = previous,
              prev.author.id == msg.author.id,
              msg.referencedMessage == nil,
              let d1 = prev.parsedTimestamp,
              let d2 = msg.parsedTimestamp else {
            return false
        }
        return d2.timeIntervalSince(d1) < 300
    }

    private func resolvedMember(for msg: DiscordMessage) -> DiscordMember {
        if let found = members.first(where: { $0.user?.id == msg.author.id }) {
            return found
        }
        if var m = msg.member {
            m.user = m.user ?? msg.author
            return m
        }
        return DiscordMember(user: msg.author, nick: nil, roles: [], avatar: nil, joinedAt: nil)
    }

    private func messageRow(_ msg: DiscordMessage, grouped: Bool) -> some View {
        let memberObj = resolvedMember(for: msg)
        let displayName = memberObj.displayName(fallback: msg.author.displayName)
        let roleColor = memberObj.highestRoleColor(in: guild?.roles ?? []) ?? vault.primaryTextColor
        let avatarURL = memberObj.avatarURL(guildId: guild?.id ?? msg.guildId, size: 128) ?? msg.author.avatarURL(size: 128)

        return VStack(alignment: .leading, spacing: 4) {
            if let ref = msg.referencedMessage {
                HStack(spacing: 6) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 10))
                        .foregroundColor(vault.secondaryTextColor)
                    Text(ref.author?.displayName ?? "Tin nhắn gốc")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(vault.accentColor)
                    Text(ref.content?.isEmpty == false ? ref.content! : "[Đính kèm]")
                        .font(.caption2)
                        .foregroundColor(vault.secondaryTextColor)
                        .lineLimit(1)
                }
                .padding(.leading, 48)
                .padding(.top, 4)
            }

            HStack(alignment: .top, spacing: 10) {
                if grouped {
                    Spacer()
                        .frame(width: 38)
                } else {
                    Button {
                        inspectedMember = memberObj
                    } label: {
                        AsyncImage(url: avatarURL) { phase in
                            switch phase {
                            case .success(let img):
                                img.resizable().scaledToFill()
                            default:
                                Circle().fill(vault.surfaceColor)
                            }
                        }
                        .frame(width: 38, height: 38)
                        .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 4) {
                    if !grouped {
                        HStack(spacing: 6) {
                            Button {
                                inspectedMember = memberObj
                            } label: {
                                Text(displayName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(roleColor)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)

                            if msg.author.bot == true {
                                Text("APP")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color(red: 0.345, green: 0.396, blue: 0.949))
                                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            }

                            Text(DiscordDateParser.formatShort(msg.timestamp))
                                .font(.caption2)
                                .foregroundColor(vault.secondaryTextColor)

                            if msg.pinned == true {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.orange)
                            }
                        }
                    }

                    if !msg.content.isEmpty {
                        RichMessageContentView(
                            rawContent: msg.content,
                            isEdited: msg.editedTimestamp != nil,
                            guild: guild,
                            mentions: msg.mentions,
                            members: members
                        )
                    }

                    ForEach(msg.attachments) { att in
                        attachmentView(att)
                    }

                    ForEach(msg.embeds) { embed in
                        EmbedCardView(embed: embed) { url in
                            previewImageItem = IdentifiableURL(url: url, title: embed.title ?? "Ảnh")
                        }
                    }

                    if let comps = msg.components, !comps.isEmpty {
                        MessageComponentsRendererView(components: comps) { url, title in
                            previewImageItem = IdentifiableURL(url: url, title: title)
                        }
                    }

                    if let rxns = msg.reactions, !rxns.isEmpty {
                        reactionBar(rxns, message: msg)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, grouped ? 2 : 5)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                replyTarget = msg
            } label: {
                Label("Trả lời", systemImage: "arrowshape.turn.up.left")
            }

            Button {
                reactionTarget = msg
            } label: {
                Label("Thêm biểu cảm", systemImage: "face.smiling")
            }

            if msg.author.id == gateway.botUser?.id {
                Button {
                    editingTarget = msg
                    composerText = msg.content
                } label: {
                    Label("Sửa nội dung", systemImage: "pencil")
                }

                Button {
                    editingEmbedTarget = msg
                } label: {
                    Label("Sửa / Gắn Embed & Nút", systemImage: "rectangle.text.badge.plus")
                }
            }

            Button {
                Task {
                    await gateway.pinMessage(channelId: channel.id, messageId: msg.id, pin: !(msg.pinned ?? false))
                }
            } label: {
                Label((msg.pinned ?? false) ? "Bỏ ghim" : "Ghim tin nhắn", systemImage: (msg.pinned ?? false) ? "pin.slash" : "pin")
            }

            Button {
                inspectedMember = memberObj
            } label: {
                Label("Xem hồ sơ thành viên", systemImage: "person.crop.circle")
            }

            Button {
                composerText += " <@\(msg.author.id)> "
            } label: {
                Label("Nhắc tên (@)", systemImage: "at")
            }

            Button {
                UIPasteboard.general.string = msg.content
            } label: {
                Label("Sao chép nội dung", systemImage: "doc.on.doc")
            }

            Button {
                UIPasteboard.general.string = msg.id
            } label: {
                Label("Sao chép Message ID", systemImage: "number")
            }

            Button(role: .destructive) {
                Task {
                    try? await gateway.deleteMessage(channelId: channel.id, messageId: msg.id)
                }
            } label: {
                Label("Xóa tin nhắn", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func attachmentView(_ att: DiscordAttachment) -> some View {
        if att.isImage, let url = URL(string: att.url) {
            Button {
                previewImageItem = IdentifiableURL(url: url, title: att.filename)
            } label: {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable()
                            .scaledToFit()
                            .frame(maxWidth: 260, maxHeight: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    case .failure:
                        fileChip(att)
                    default:
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(vault.surfaceColor)
                            .frame(width: 200, height: 130)
                            .overlay(ProgressView())
                    }
                }
            }
            .buttonStyle(.plain)
        } else if att.isVideo, let url = URL(string: att.url) {
            Button {
                previewVideoItem = IdentifiableURL(url: url, title: att.filename)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "play.rectangle.fill")
                        .font(.title3)
                        .foregroundColor(vault.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(att.filename)
                            .font(.caption.weight(.semibold))
                            .foregroundColor(vault.primaryTextColor)
                            .lineLimit(1)
                        Text("Video • \(att.formattedSize)")
                            .font(.caption2)
                            .foregroundColor(vault.secondaryTextColor)
                    }
                    Spacer()
                }
                .padding(10)
                .background(vault.surfaceColor)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
        } else {
            Button {
                if let url = URL(string: att.url) {
                    UIApplication.shared.open(url)
                }
            } label: {
                fileChip(att)
            }
            .buttonStyle(.plain)
        }
    }

    private func fileChip(_ att: DiscordAttachment) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.fill")
                .foregroundColor(vault.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(att.filename)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(vault.primaryTextColor)
                    .lineLimit(1)
                Text(att.formattedSize)
                    .font(.caption2)
                    .foregroundColor(vault.secondaryTextColor)
            }
            Spacer(minLength: 4)
            Image(systemName: "arrow.down.circle")
                .foregroundColor(vault.secondaryTextColor)
        }
        .padding(10)
        .background(vault.surfaceColor)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func reactionBar(_ reactions: [DiscordReaction], message: DiscordMessage) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(reactions) { rxn in
                    Button {
                        Task {
                            await gateway.toggleReaction(
                                channelId: channel.id,
                                messageId: message.id,
                                emojiIdentifier: rxn.emoji.apiIdentifier,
                                currentlyMine: rxn.me
                            )
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if let imgURL = rxn.emoji.imageURL {
                                AnimatedEmojiImageView(url: imgURL, size: 16)
                            } else {
                                Text(rxn.emoji.name ?? "?")
                                    .font(.caption)
                            }
                            Text("\(rxn.count)")
                                .font(.caption2.monospacedDigit().weight(.semibold))
                                .foregroundColor(rxn.me ? vault.accentColor : vault.secondaryTextColor)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(rxn.me ? vault.accentColor.opacity(0.18) : vault.surfaceColor)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(rxn.me ? vault.accentColor : vault.dividerColor, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Typing Indicator & Autocomplete

    @ViewBuilder
    private var typingBar: some View {
        if !typingUsers.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "ellipsis.bubble.fill")
                    .font(.caption2)
                    .foregroundColor(vault.accentColor)
                Text("\(typingUsers.prefix(3).joined(separator: ", ")) đang nhập...")
                    .font(.caption2)
                    .foregroundColor(vault.secondaryTextColor)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(vault.backgroundColor)
        }
    }

    @ViewBuilder
    private var autocompleteBar: some View {
        if let trigger = activeTrigger() {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    switch trigger.kind {
                    case .member:
                        let list = members.filter {
                            trigger.query.isEmpty ||
                            $0.displayName().lowercased().contains(trigger.query) ||
                            ($0.user?.username.lowercased().contains(trigger.query) ?? false)
                        }.prefix(10)
                        ForEach(Array(list)) { m in
                            Button {
                                if let uid = m.user?.id {
                                    applyAutocomplete(replacement: "<@\(uid)> ")
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "at")
                                        .font(.caption2)
                                    Text(m.displayName())
                                        .font(.caption.weight(.medium))
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(vault.surfaceColor)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }

                    case .channel:
                        let chans = (guild?.channels ?? []).filter {
                            !$0.isCategory &&
                            (trigger.query.isEmpty || $0.displayName.lowercased().contains(trigger.query))
                        }.prefix(10)
                        ForEach(Array(chans)) { ch in
                            Button {
                                applyAutocomplete(replacement: "<#\(ch.id)> ")
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: ch.sfSymbolName)
                                        .font(.caption2)
                                    Text(ch.displayName)
                                        .font(.caption.weight(.medium))
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(vault.surfaceColor)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }

                    case .emoji:
                        let allEmojis = (guild?.emojis ?? []) + gateway.applicationEmojis
                        let emojis = allEmojis.filter {
                            trigger.query.isEmpty || $0.name.lowercased().contains(trigger.query)
                        }.prefix(12)
                        ForEach(Array(emojis)) { em in
                            Button {
                                let text = vault.emojiInsertAsHyperlink ? em.hyperlinkMarkdown : em.markdownString
                                applyAutocomplete(replacement: "\(text) ")
                            } label: {
                                HStack(spacing: 4) {
                                    AnimatedEmojiImageView(url: em.imageURL, size: 16)
                                    Text(":\(em.name):")
                                        .font(.caption)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(vault.surfaceColor)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .background(vault.elevatedSurfaceColor)
        }
    }

    private enum TriggerKind { case member, channel, emoji }
    private struct AutocompleteTrigger { let kind: TriggerKind; let query: String }

    private func activeTrigger() -> AutocompleteTrigger? {
        guard let lastWord = composerText.split(separator: " ", omittingEmptySubsequences: false).last else {
            return nil
        }
        let s = String(lastWord)
        if s.hasPrefix("@") {
            return AutocompleteTrigger(kind: .member, query: String(s.dropFirst()).lowercased())
        }
        if s.hasPrefix("#") {
            return AutocompleteTrigger(kind: .channel, query: String(s.dropFirst()).lowercased())
        }
        if s.hasPrefix(":") && s.count >= 2 && !s.dropFirst().contains(":") {
            return AutocompleteTrigger(kind: .emoji, query: String(s.dropFirst()).lowercased())
        }
        return nil
    }

    private func applyAutocomplete(replacement: String) {
        if let spaceIdx = composerText.lastIndex(of: " ") {
            let prefix = String(composerText[...spaceIdx])
            composerText = prefix + replacement
        } else {
            composerText = replacement
        }
    }

    // MARK: - Composer

    private var composerContainer: some View {
        VStack(spacing: 6) {
            if let err = sendError {
                HStack {
                    Text(err)
                        .font(.caption2)
                        .foregroundColor(.red)
                    Spacer()
                    Button {
                        sendError = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                    }
                }
                .padding(.horizontal, 12)
            }

            if let reply = replyTarget {
                HStack(spacing: 6) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.caption2)
                        .foregroundColor(vault.accentColor)
                    Text("Đang trả lời \(reply.author.displayName)")
                        .font(.caption.weight(.medium))
                        .foregroundColor(vault.secondaryTextColor)
                    Spacer()
                    Button {
                        replyTarget = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(vault.secondaryTextColor)
                    }
                }
                .padding(.horizontal, 12)
            } else if editingTarget != nil {
                HStack(spacing: 6) {
                    Image(systemName: "pencil")
                        .font(.caption2)
                        .foregroundColor(.orange)
                    Text("Đang chỉnh sửa tin nhắn")
                        .font(.caption.weight(.medium))
                        .foregroundColor(vault.secondaryTextColor)
                    Spacer()
                    Button {
                        editingTarget = nil
                        composerText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(vault.secondaryTextColor)
                    }
                }
                .padding(.horizontal, 12)
            }

            if !pendingAttachments.isEmpty || !pendingEmbeds.isEmpty || !pendingComponents.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(pendingAttachments.enumerated()), id: \.element.id) { idx, item in
                            HStack(spacing: 6) {
                                Image(systemName: "paperclip")
                                    .font(.caption2)
                                Text(item.filename)
                                    .font(.caption2)
                                    .lineLimit(1)
                                Button {
                                    pendingAttachments.remove(at: idx)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption2)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(vault.elevatedSurfaceColor)
                            .clipShape(Capsule())
                        }
                        ForEach(Array(pendingEmbeds.enumerated()), id: \.offset) { idx, emb in
                            HStack(spacing: 6) {
                                Image(systemName: "rectangle.text.badge.plus")
                                    .font(.caption2)
                                Text(emb.title ?? "Embed")
                                    .font(.caption2)
                                    .lineLimit(1)
                                Button {
                                    pendingEmbeds.remove(at: idx)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption2)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(vault.accentColor.opacity(0.22))
                            .clipShape(Capsule())
                        }
                        if !pendingComponents.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: "rectangle.grid.2x2")
                                    .font(.caption2)
                                Text("\(pendingComponents.count) hàng nút")
                                    .font(.caption2)
                                Button {
                                    pendingComponents.removeAll()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption2)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(vault.accentColor.opacity(0.22))
                            .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }

            Divider().background(vault.dividerColor)

            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button {
                        showPhotoPicker = true
                    } label: {
                        Label("Chọn Ảnh / Video", systemImage: "photo.on.rectangle")
                    }
                    Button {
                        showDocumentPicker = true
                    } label: {
                        Label("Chọn Tệp đính kèm", systemImage: "doc")
                    }
                    Button {
                        showMessageStudio = true
                    } label: {
                        Label("Message Studio (Embed / Components V2)", systemImage: "rectangle.text.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(vault.secondaryTextColor)
                }

                Button {
                    showEmojiPicker = true
                } label: {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 24))
                        .foregroundColor(vault.secondaryTextColor)
                }
                .buttonStyle(.plain)

                Group {
                    if #available(iOS 16.0, *) {
                        TextField("Nhắn vào #\(channel.displayName)...", text: $composerText, axis: .vertical)
                            .lineLimit(1...5)
                    } else {
                        TextField("Nhắn vào #\(channel.displayName)...", text: $composerText)
                    }
                }
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(vault.elevatedSurfaceColor)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                let canSend = !isSending && (
                    !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    !pendingAttachments.isEmpty ||
                    !pendingEmbeds.isEmpty ||
                    !pendingComponents.isEmpty
                )

                Button {
                    Task { await sendAction() }
                } label: {
                    Group {
                        if isSending {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 30))
                        }
                    }
                    .foregroundColor(canSend ? vault.accentColor : vault.secondaryTextColor.opacity(0.45))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(vault.surfaceColor)
    }

    private func sendAction() async {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingAttachments.isEmpty || !pendingEmbeds.isEmpty || !pendingComponents.isEmpty else { return }
        isSending = true
        sendError = nil
        defer { isSending = false }

        do {
            if let editMsg = editingTarget {
                try await gateway.editMessage(
                    channelId: channel.id,
                    messageId: editMsg.id,
                    content: text,
                    embeds: editMsg.embeds,
                    components: editMsg.components
                )
                editingTarget = nil
            } else {
                try await gateway.sendMessage(
                    channelId: channel.id,
                    content: text,
                    embeds: pendingEmbeds,
                    components: pendingComponents,
                    replyToMessageId: replyTarget?.id,
                    attachments: pendingAttachments
                )
                replyTarget = nil
                pendingAttachments = []
                pendingEmbeds = []
                pendingComponents = []
            }
            composerText = ""
        } catch {
            sendError = error.localizedDescription
        }
    }
}

private struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
}

private struct EmbedCardView: View {
    let embed: DiscordEmbed
    let onTapImage: (URL) -> Void
    @EnvironmentObject private var vault: BotVaultStore

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(embed.accentColor)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 5) {
                        if let author = embed.author {
                            Text(author.name)
                                .font(.caption.weight(.semibold))
                                .foregroundColor(vault.primaryTextColor)
                        }
                        if let title = embed.title, !title.isEmpty {
                            Text(title)
                                .font(.subheadline.weight(.bold))
                                .foregroundColor(embed.url != nil ? vault.accentColor : vault.primaryTextColor)
                        }
                        if let desc = embed.description, !desc.isEmpty {
                            RichMessageContentView(
                                rawContent: desc,
                                isEdited: false,
                                guild: nil,
                                mentions: nil,
                                members: []
                            )
                        }
                    }
                    Spacer(minLength: 0)
                    if let thumb = embed.thumbnail?.url, let tURL = URL(string: thumb) {
                        AsyncImage(url: tURL) { ph in
                            if case .success(let img) = ph {
                                img.resizable().scaledToFill()
                            }
                        }
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }

                if let fields = embed.fields, !fields.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(fields) { f in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(f.name)
                                    .font(.caption.weight(.bold))
                                    .foregroundColor(vault.primaryTextColor)
                                Text(f.value)
                                    .font(.caption2)
                                    .foregroundColor(vault.secondaryTextColor)
                            }
                        }
                    }
                }

                if let imgStr = embed.image?.url, let iURL = URL(string: imgStr) {
                    Button {
                        onTapImage(iURL)
                    } label: {
                        AsyncImage(url: iURL) { ph in
                            if case .success(let img) = ph {
                                img.resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: 250, maxHeight: 200)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }

                if let footer = embed.footer {
                    Text(footer.text)
                        .font(.caption2)
                        .foregroundColor(vault.secondaryTextColor)
                }
            }
            .padding(10)
        }
        .background(vault.surfaceColor)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ReactionPickerSheet: View {
    let currentGuild: DiscordGuild?
    let existingReactions: [DiscordReaction]
    let onSelect: (String, Bool) -> Void

    @EnvironmentObject private var vault: BotVaultStore
    @EnvironmentObject private var gateway: DiscordGatewayService
    @Environment(\.dismiss) private var dismiss

    @State private var customEmoji = ""
    @State private var searchQuery = ""

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 8), count: 6)

    var body: some View {
        NavigationView {
            List {
                Section("Nhập biểu cảm bất kỳ") {
                    HStack {
                        TextField("Dán 1 emoji hoặc name:id...", text: $customEmoji)
                        Button("Gửi") {
                            let clean = customEmoji.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !clean.isEmpty {
                                onSelect(clean, false)
                                dismiss()
                            }
                        }
                        .disabled(customEmoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                if !existingReactions.isEmpty {
                    Section("Biểu cảm hiện có trên tin nhắn") {
                        ForEach(existingReactions) { rxn in
                            Button {
                                onSelect(rxn.emoji.apiIdentifier, rxn.me)
                                dismiss()
                            } label: {
                                HStack(spacing: 8) {
                                    if let url = rxn.emoji.imageURL {
                                        AnimatedEmojiImageView(url: url, size: 20)
                                    }
                                    Text(rxn.emoji.displayLabel)
                                    Spacer()
                                    Text(rxn.me ? "Bỏ chọn (\(rxn.count))" : "Thêm (\(rxn.count))")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }

                let serverEmojis = (currentGuild?.emojis ?? [])
                    .filter { searchQuery.isEmpty || $0.name.lowercased().contains(searchQuery.lowercased()) }
                if !serverEmojis.isEmpty {
                    Section("Emoji của máy chủ") {
                        LazyVGrid(columns: cols, spacing: 8) {
                            ForEach(serverEmojis) { em in
                                Button {
                                    onSelect(em.apiIdentifier, false)
                                    dismiss()
                                } label: {
                                    AnimatedEmojiImageView(url: em.imageURL, size: 30)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                let appEmojis = gateway.applicationEmojis
                    .filter { searchQuery.isEmpty || $0.name.lowercased().contains(searchQuery.lowercased()) }
                if !appEmojis.isEmpty {
                    Section("Emoji ứng dụng Bot") {
                        LazyVGrid(columns: cols, spacing: 8) {
                            ForEach(appEmojis) { em in
                                Button {
                                    onSelect(em.apiIdentifier, false)
                                    dismiss()
                                } label: {
                                    AnimatedEmojiImageView(url: em.imageURL, size: 30)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .searchable(text: $searchQuery, prompt: "Tìm emoji...")
            .navigationTitle("Biểu cảm")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Đóng") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

private struct PinnedMessagesSheet: View {
    let channelId: String
    let guild: DiscordGuild?
    let members: [DiscordMember]
    @EnvironmentObject private var gateway: DiscordGatewayService
    @Environment(\.dismiss) private var dismiss

    @State private var pins: [DiscordMessage] = []
    @State private var isLoading = true

    var body: some View {
        NavigationView {
            List {
                if isLoading {
                    ProgressView()
                } else if pins.isEmpty {
                    Text("Kênh này chưa có tin nhắn nào được ghim.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(pins) { msg in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(msg.author.displayName)
                                .font(.caption.weight(.bold))
                            Text(DiscordTextFormatter.renderCleanText(msg.content, guild: guild, mentions: msg.mentions, members: members))
                                .font(.subheadline)
                        }
                    }
                }
            }
            .navigationTitle("Tin nhắn đã ghim")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Đóng") { dismiss() }
                }
            }
            .task {
                pins = (try? await DiscordRESTClient.shared.fetchPinnedMessages(channelId: channelId, token: gateway.currentToken)) ?? []
                isLoading = false
            }
        }
        .navigationViewStyle(.stack)
    }
}

private struct PurgeMessagesSheet: View {
    let channelId: String
    @EnvironmentObject private var gateway: DiscordGatewayService
    @Environment(\.dismiss) private var dismiss

    @State private var count: Int = 10
    @State private var isPurging = false
    @State private var errMsg: String?

    var body: some View {
        NavigationView {
            Form {
                Section("Xóa hàng loạt (Bulk Delete)") {
                    Stepper("Số lượng tin gần nhất: \(count)", value: $count, in: 2...100)
                    Text("Lưu ý: Discord chỉ cho phép xóa hàng loạt các tin nhắn chưa quá 14 ngày.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let err = errMsg {
                    Section {
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        Task {
                            isPurging = true
                            errMsg = nil
                            do {
                                try await gateway.purgeRecentMessages(channelId: channelId, count: count)
                                dismiss()
                            } catch {
                                errMsg = error.localizedDescription
                            }
                            isPurging = false
                        }
                    } label: {
                        HStack {
                            Text(isPurging ? "Đang xóa..." : "Xóa \(count) tin nhắn")
                            Spacer()
                            if isPurging { ProgressView() }
                        }
                    }
                    .disabled(isPurging)
                }
            }
            .navigationTitle("Dọn dẹp kênh")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Hủy") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
