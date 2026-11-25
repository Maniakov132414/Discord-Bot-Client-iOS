import SwiftUI

struct EmojiPickerSheet: View {
    let currentGuild: DiscordGuild?
    let onInsertText: (String) -> Void

    @EnvironmentObject private var vault: BotVaultStore
    @EnvironmentObject private var gateway: DiscordGatewayService
    @Environment(\.dismiss) private var dismiss

    @State private var searchQuery = ""
    @State private var quickInput = ""
    @State private var quickName = ""
    @State private var quickError: String?

    private let gridColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 6)

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Mode Switcher & Search
                VStack(spacing: 10) {
                    Picker("Kiểu chèn", selection: $vault.emojiInsertAsHyperlink) {
                        Text("Emoji gốc <:name:id>").tag(false)
                        Text("Hyperlink [name](cdn...)").tag(true)
                    }
                    .pickerStyle(.segmented)

                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.caption)
                            .foregroundColor(vault.secondaryTextColor)
                        TextField("Tìm emoji...", text: $searchQuery)
                            .font(.subheadline)
                            .textFieldStyle(.plain)
                        if !searchQuery.isEmpty {
                            Button {
                                searchQuery = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundColor(vault.secondaryTextColor)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(9)
                    .background(vault.elevatedSurfaceColor)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    // Quick Hyperlink Generator
                    HStack(spacing: 6) {
                        TextField("Dán URL hoặc Emoji ID...", text: $quickInput)
                            .font(.caption)
                            .textFieldStyle(.plain)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .padding(8)
                            .background(vault.elevatedSurfaceColor)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                        TextField("Tên", text: $quickName)
                            .font(.caption)
                            .textFieldStyle(.plain)
                            .frame(width: 72)
                            .padding(8)
                            .background(vault.elevatedSurfaceColor)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                        Button {
                            insertQuickHyperlink()
                        } label: {
                            Image(systemName: "link.badge.plus")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(vault.accentColor)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(quickInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if let err = quickError {
                        Text(err)
                            .font(.caption2)
                            .foregroundColor(.red)
                    }
                }
                .padding(12)
                .background(vault.surfaceColor)

                Divider().background(vault.dividerColor)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if let g = currentGuild {
                            let filtered = filterEmojis(g.emojis)
                            if !filtered.isEmpty {
                                emojiSection(title: "Máy chủ hiện tại (\(g.name))", emojis: filtered)
                            }
                        }

                        let appFiltered = filterEmojis(gateway.applicationEmojis)
                        if !appFiltered.isEmpty {
                            emojiSection(title: "Emoji ứng dụng Bot", emojis: appFiltered)
                        }

                        ForEach(gateway.guilds.filter { $0.id != currentGuild?.id }) { otherGuild in
                            let filtered = filterEmojis(otherGuild.emojis)
                            if !filtered.isEmpty {
                                emojiSection(title: otherGuild.name, emojis: filtered)
                            }
                        }
                    }
                    .padding(12)
                }
                .background(vault.backgroundColor)
            }
            .navigationTitle("Chọn Emoji")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Đóng") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func emojiSection(title: String, emojis: [DiscordEmoji]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundColor(vault.secondaryTextColor)

            LazyVGrid(columns: gridColumns, spacing: 10) {
                ForEach(emojis) { emoji in
                    Button {
                        let out = vault.emojiInsertAsHyperlink ? emoji.hyperlinkMarkdown : emoji.markdownString
                        onInsertText("\(out) ")
                        dismiss()
                    } label: {
                        VStack(spacing: 3) {
                            AnimatedEmojiImageView(url: emoji.imageURL, size: 34)
                            Text(emoji.name)
                                .font(.system(size: 9))
                                .foregroundColor(vault.secondaryTextColor)
                                .lineLimit(1)
                        }
                        .padding(4)
                        .frame(maxWidth: .infinity)
                        .background(vault.surfaceColor.opacity(0.75))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func filterEmojis(_ list: [DiscordEmoji]) -> [DiscordEmoji] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return list }
        return list.filter { $0.name.lowercased().contains(q) }
    }

    private func insertQuickHyperlink() {
        quickError = nil
        let raw = quickInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

        var eid = ""
        var animated = false
        var parsedName = quickName.trimmingCharacters(in: .whitespacesAndNewlines)

        if let regex = try? NSRegularExpression(pattern: #"emojis/(\d+)\.(gif|webp|png)"#),
           let m = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
           let idR = Range(m.range(at: 1), in: raw),
           let extR = Range(m.range(at: 2), in: raw) {
            eid = String(raw[idR])
            animated = String(raw[extR]).lowercased() == "gif"
            if parsedName.isEmpty,
               let comps = URLComponents(string: raw),
               let qName = comps.queryItems?.first(where: { $0.name == "name" })?.value {
                parsedName = qName
            }
        } else if raw.allSatisfy(\.isNumber) && raw.count >= 15 {
            eid = raw
        } else {
            quickError = "Hãy nhập URL emoji Discord hợp lệ hoặc Emoji ID."
            return
        }

        let safeName = parsedName.isEmpty ? "emoji" : parsedName
        let md = animated
            ? "[\(safeName)](https://cdn.discordapp.com/emojis/\(eid).gif?size=48&name=\(safeName))"
            : "[\(safeName)](https://cdn.discordapp.com/emojis/\(eid).webp?size=48&name=\(safeName)&lossless=true)"
        onInsertText("\(md) ")
        dismiss()
    }
}
