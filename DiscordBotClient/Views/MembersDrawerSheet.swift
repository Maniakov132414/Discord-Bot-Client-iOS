import SwiftUI
import UIKit

struct MembersDrawerSheet: View {
    let guildId: String
    let guild: DiscordGuild?
    let roles: [DiscordRole]
    let onMention: (DiscordMember) -> Void
    let onOpenDMChannel: (DiscordChannel) -> Void

    @EnvironmentObject private var vault: BotVaultStore
    @EnvironmentObject private var gateway: DiscordGatewayService
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var searchResults: [DiscordMember] = []
    @State private var selectedMember: DiscordMember?

    var body: some View {
        NavigationView {
            List {
                ForEach(groupedSections, id: \.title) { section in
                    Section {
                        ForEach(section.members) { member in
                            Button {
                                selectedMember = member
                            } label: {
                                memberRow(member)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("\(section.title.uppercased()) — \(section.members.count)")
                            .font(.caption2.weight(.bold))
                            .foregroundColor(section.color ?? vault.secondaryTextColor)
                    }
                }
            }
            .searchable(text: $query, prompt: "Tìm thành viên...")
            .onChange(of: query) { newQ in
                Task {
                    let q = newQ.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !q.isEmpty {
                        searchResults = await gateway.searchMembers(guildId: guildId, query: q)
                    } else {
                        searchResults = []
                    }
                }
            }
            .navigationTitle("Thành viên")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Đóng") { dismiss() }
                }
            }
            .sheet(item: $selectedMember) { member in
                MemberProfileSheet(
                    member: member,
                    guildId: guildId,
                    roles: roles,
                    onMention: { m in
                        onMention(m)
                        dismiss()
                    },
                    onOpenDMChannel: { dmChannel in
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            onOpenDMChannel(dmChannel)
                        }
                    }
                )
                .environmentObject(vault)
                .environmentObject(gateway)
            }
        }
        .navigationViewStyle(.stack)
    }

    private func memberRow(_ member: DiscordMember) -> some View {
        HStack(spacing: 10) {
            AsyncImage(url: member.avatarURL(guildId: guildId, size: 96)) { ph in
                if case .success(let img) = ph {
                    img.resizable().scaledToFill()
                } else {
                    Circle().fill(vault.elevatedSurfaceColor)
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(member.displayName())
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(member.highestRoleColor(in: roles) ?? vault.primaryTextColor)
                        .lineLimit(1)
                    if member.user?.bot == true {
                        Text("APP")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(Color(red: 0.345, green: 0.396, blue: 0.949))
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    }
                }
                if let uname = member.user?.username {
                    Text("@\(uname)")
                        .font(.caption2)
                        .foregroundColor(vault.secondaryTextColor)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundColor(vault.secondaryTextColor.opacity(0.6))
        }
    }

    private struct RoleSection {
        let title: String
        let color: Color?
        let position: Int
        var members: [DiscordMember]
    }

    private var displayedMembers: [DiscordMember] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = gateway.membersByGuild[guildId] ?? []
        if !q.isEmpty {
            if !searchResults.isEmpty { return searchResults }
            return base.filter {
                $0.displayName().lowercased().contains(q) ||
                ($0.user?.username.lowercased().contains(q) ?? false) ||
                ($0.user?.id.contains(q) ?? false)
            }
        }
        return base
    }

    private var groupedSections: [RoleSection] {
        let members = displayedMembers
        let nonEveryoneRoles = roles.filter { $0.id != guildId && $0.name != "@everyone" }
        let hasHoisted = nonEveryoneRoles.contains { $0.hoist == true }

        var buckets: [String: RoleSection] = [:]
        var ungrouped: [DiscordMember] = []

        for m in members {
            let roleSet = Set(m.roles)
            let candidate = nonEveryoneRoles
                .filter { roleSet.contains($0.id) && (!hasHoisted || $0.hoist == true) }
                .sorted { $0.position > $1.position }
                .first

            if let role = candidate {
                if var existing = buckets[role.id] {
                    existing.members.append(m)
                    buckets[role.id] = existing
                } else {
                    buckets[role.id] = RoleSection(
                        title: role.name,
                        color: role.swiftUIColor,
                        position: role.position,
                        members: [m]
                    )
                }
            } else {
                ungrouped.append(m)
            }
        }

        var ordered = buckets.values.sorted { $0.position > $1.position }.map { sec -> RoleSection in
            var copy = sec
            copy.members.sort { $0.displayName().localizedCaseInsensitiveCompare($1.displayName()) == .orderedAscending }
            return copy
        }

        if !ungrouped.isEmpty {
            let sortedRest = ungrouped.sorted {
                $0.displayName().localizedCaseInsensitiveCompare($1.displayName()) == .orderedAscending
            }
            ordered.append(RoleSection(title: "Thành viên", color: nil, position: -1, members: sortedRest))
        }
        return ordered
    }
}

struct MemberProfileSheet: View {
    let member: DiscordMember
    let guildId: String?
    let roles: [DiscordRole]
    let onMention: (DiscordMember) -> Void
    let onOpenDMChannel: (DiscordChannel) -> Void

    @EnvironmentObject private var vault: BotVaultStore
    @EnvironmentObject private var gateway: DiscordGatewayService
    @Environment(\.dismiss) private var dismiss

    @State private var isOpeningDM = false
    @State private var statusBanner: String?

    private var memberRoles: [DiscordRole] {
        let set = Set(member.roles)
        return roles
            .filter { set.contains($0.id) && $0.id != guildId && $0.name != "@everyone" }
            .sorted { $0.position > $1.position }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    let avatarURL = member.avatarURL(guildId: guildId, size: 256)

                    VStack(spacing: 10) {
                        AsyncImage(url: avatarURL) { ph in
                            if case .success(let img) = ph {
                                img.resizable().scaledToFill()
                            } else {
                                Circle().fill(vault.elevatedSurfaceColor)
                            }
                        }
                        .frame(width: 68, height: 68)
                        .clipShape(Circle())

                        HStack(spacing: 6) {
                            Text(member.displayName())
                                .font(.title3.weight(.bold))
                                .foregroundColor(member.highestRoleColor(in: roles) ?? vault.primaryTextColor)
                            if member.user?.bot == true {
                                Text("APP")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color(red: 0.345, green: 0.396, blue: 0.949))
                                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            }
                        }

                        if let uname = member.user?.username {
                            Text("@\(uname)")
                                .font(.subheadline)
                                .foregroundColor(vault.secondaryTextColor)
                        }

                        if let uid = member.user?.id {
                            Text("ID: \(uid)")
                                .font(.caption.monospaced())
                                .foregroundColor(vault.secondaryTextColor)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(vault.elevatedSurfaceColor)
                                .clipShape(Capsule())
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(16)
                    .background(vault.surfaceColor)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    if !memberRoles.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("VAI TRÒ (\(memberRoles.count))")
                                .font(.caption2.weight(.bold))
                                .foregroundColor(vault.secondaryTextColor)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(memberRoles) { r in
                                        HStack(spacing: 5) {
                                            Circle()
                                                .fill(r.swiftUIColor ?? Color.gray)
                                                .frame(width: 8, height: 8)
                                            Text(r.name)
                                                .font(.caption.weight(.medium))
                                                .foregroundColor(vault.primaryTextColor)
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(vault.elevatedSurfaceColor)
                                        .clipShape(Capsule())
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(vault.surfaceColor)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }

                    VStack(spacing: 8) {
                        if let uid = member.user?.id, member.user?.bot != true {
                            actionRow(
                                title: isOpeningDM ? "Đang mở kênh DM..." : "Nhắn tin riêng (Mở DM)",
                                icon: "bubble.left.and.bubble.right.fill",
                                accent: true
                            ) {
                                Task {
                                    isOpeningDM = true
                                    do {
                                        let ch = try await gateway.openDM(recipientId: uid)
                                        dismiss()
                                        onOpenDMChannel(ch)
                                    } catch {
                                        statusBanner = error.localizedDescription
                                    }
                                    isOpeningDM = false
                                }
                            }
                        }

                        actionRow(title: "Nhắc tên (@Mention)", icon: "at") {
                            onMention(member)
                            dismiss()
                        }

                        if let uid = member.user?.id {
                            actionRow(title: "Sao chép User ID", icon: "number") {
                                UIPasteboard.general.string = uid
                                statusBanner = "Đã sao chép User ID."
                            }
                            actionRow(title: "Sao chép thẻ <@\(uid)>", icon: "tag") {
                                UIPasteboard.general.string = "<@\(uid)>"
                                statusBanner = "Đã sao chép thẻ <@\(uid)>."
                            }
                        }

                        if let uname = member.user?.username {
                            actionRow(title: "Sao chép @\(uname)", icon: "person") {
                                UIPasteboard.general.string = "@\(uname)"
                                statusBanner = "Đã sao chép @\(uname)."
                            }
                        }

                        if let aURL = avatarURL?.absoluteString {
                            actionRow(title: "Sao chép link Avatar", icon: "link") {
                                UIPasteboard.general.string = aURL
                                statusBanner = "Đã sao chép link Avatar."
                            }
                        }
                    }

                    if let note = statusBanner {
                        Text(note)
                            .font(.caption)
                            .foregroundColor(vault.accentColor)
                    }
                }
                .padding(16)
            }
            .background(vault.backgroundColor.ignoresSafeArea())
            .navigationTitle("Hồ sơ thành viên")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Đóng") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func actionRow(title: String, icon: String, accent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundColor(accent ? .white : vault.accentColor)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(accent ? .white : vault.primaryTextColor)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(accent ? .white.opacity(0.8) : vault.secondaryTextColor)
            }
            .padding(13)
            .background(accent ? vault.accentColor : vault.surfaceColor)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
