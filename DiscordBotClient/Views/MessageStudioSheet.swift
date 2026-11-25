import SwiftUI

struct MessageStudioSheet: View {
    enum StudioTab: Int, CaseIterable, Identifiable {
        case v1EmbedButtons = 0
        case v2Components = 1
        var id: Int { rawValue }
    }

    struct DraftButton: Identifiable {
        let id = UUID()
        var label: String = "Nút bấm"
        var style: Int = 1 // 1=Primary, 2=Secondary, 3=Success, 4=Danger, 5=Link
        var url: String = ""
        var customId: String = "btn_\(Int.random(in: 1000...9999))"
        var emojiText: String = ""
        var autoReply: String = ""
        var ephemeral: Bool = true
    }

    enum V2BlockKind: String, CaseIterable {
        case textDisplay = "Văn bản (TextDisplay)"
        case section = "Đoạn + Ảnh nhỏ (Section)"
        case gallery = "Thư viện ảnh (MediaGallery)"
        case separator = "Đường kẻ (Separator)"
        case actionRow = "Hàng nút bấm (ActionRow)"
    }

    struct DraftV2Block: Identifiable {
        let id = UUID()
        var kind: V2BlockKind
        var text: String = ""
        var mediaURL: String = ""
        var divider: Bool = true
        var largeSpacing: Bool = false
        var buttons: [DraftButton] = [DraftButton()]
    }

    let initialEmbed: DiscordEmbed?
    let onAttachV1: (DiscordEmbed?, [DiscordComponent]) -> Void
    let onSendV2: ([DiscordComponent], Int) async throws -> Void

    @EnvironmentObject private var vault: BotVaultStore
    @Environment(\.dismiss) private var dismiss

    @State private var activeTab: StudioTab = .v1EmbedButtons

    // V1 State
    @State private var embedTitle = ""
    @State private var embedDescription = ""
    @State private var embedFooter = ""
    @State private var embedImageURL = ""
    @State private var embedThumbnailURL = ""
    @State private var embedHexColor = "#5865F2"
    @State private var v1Buttons: [DraftButton] = []

    // V2 State
    @State private var v2HexColor = "#5865F2"
    @State private var v2Spoiler = false
    @State private var v2Blocks: [DraftV2Block] = [
        DraftV2Block(kind: .textDisplay, text: "## Tiêu đề Components V2\nNội dung hiển thị trực tiếp bằng Components V2.")
    ]
    @State private var isSendingV2 = false
    @State private var studioError: String?
    @State private var emojiPickerTarget: StudioEmojiTarget?

    private enum StudioEmojiTarget: Identifiable {
        case v1Description
        case v2Block(Int)
        var id: String {
            switch self {
            case .v1Description: return "v1-desc"
            case .v2Block(let i): return "v2-\(i)"
            }
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("Chế độ", selection: $activeTab) {
                    Text("Embed + Nút bấm").tag(StudioTab.v1EmbedButtons)
                    Text("Components V2").tag(StudioTab.v2Components)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(vault.surfaceColor)

                if activeTab == .v1EmbedButtons {
                    v1StudioForm
                } else {
                    v2StudioForm
                }
            }
            .navigationTitle("Message Studio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Hủy") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if activeTab == .v1EmbedButtons {
                        Button("Áp dụng") { applyV1() }
                    } else {
                        Button(isSendingV2 ? "Đang gửi..." : "Gửi V2") {
                            Task { await sendV2Now() }
                        }
                        .disabled(isSendingV2 || builtV2Components.isEmpty)
                    }
                }
            }
            .onAppear {
                if let e = initialEmbed {
                    embedTitle = e.title ?? ""
                    embedDescription = e.description ?? ""
                    embedFooter = e.footer?.text ?? ""
                    embedImageURL = e.image?.url ?? ""
                    embedThumbnailURL = e.thumbnail?.url ?? ""
                }
            }
            .sheet(item: $emojiPickerTarget) { target in
                EmojiPickerSheet(currentGuild: nil) { snippet in
                    switch target {
                    case .v1Description:
                        embedDescription += snippet
                    case .v2Block(let idx):
                        if idx < v2Blocks.count {
                            v2Blocks[idx].text += snippet
                        }
                    }
                }
                .environmentObject(vault)
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - Tab 1: Embed + Buttons (V1)

    private var v1StudioForm: some View {
        Form {
            Section("Nội dung Embed (Chuẩn V1)") {
                TextField("Tiêu đề", text: $embedTitle)
                HStack {
                    TextField("Mô tả", text: $embedDescription)
                    Button {
                        emojiPickerTarget = .v1Description
                    } label: {
                        Image(systemName: "face.smiling")
                            .foregroundColor(vault.accentColor)
                    }
                    .buttonStyle(.borderless)
                }
                TextField("Chân trang (Footer)", text: $embedFooter)
                TextField("URL Ảnh lớn (tuỳ chọn)", text: $embedImageURL)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                TextField("URL Ảnh thu nhỏ (Thumbnail)", text: $embedThumbnailURL)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
            }

            Section("Màu viền") {
                colorPresetRow(selectedHex: $embedHexColor)
            }

            Section("Nút bấm đính kèm (tối đa 5 nút)") {
                ForEach(Array(v1Buttons.enumerated()), id: \.element.id) { idx, _ in
                    buttonEditorCard(binding: $v1Buttons[idx]) {
                        v1Buttons.remove(at: idx)
                    }
                }

                if v1Buttons.count < 5 {
                    Button {
                        v1Buttons.append(DraftButton())
                    } label: {
                        Label("Thêm nút bấm", systemImage: "plus.rectangle.fill")
                    }
                }
            }
        }
    }

    // MARK: - Tab 2: Components V2 (flags: 32768)

    private var v2StudioForm: some View {
        Form {
            Section("Container (Type 17 • flags: 32768)") {
                colorPresetRow(selectedHex: $v2HexColor)
                Toggle("Ẩn dưới dạng Spoiler", isOn: $v2Spoiler)
            }

            Section("Các khối bên trong Container") {
                ForEach(Array(v2Blocks.enumerated()), id: \.element.id) { idx, _ in
                    v2BlockEditor(idx: idx)
                }

                Menu {
                    Button { v2Blocks.append(DraftV2Block(kind: .textDisplay, text: "Nội dung mới...")) } label: {
                        Label("Thêm TextDisplay (10)", systemImage: "text.alignleft")
                    }
                    Button { v2Blocks.append(DraftV2Block(kind: .section, text: "Mục mô tả", mediaURL: "")) } label: {
                        Label("Thêm Section + Thumbnail (9+11)", systemImage: "rectangle.leadinghalf.inset.filled")
                    }
                    Button { v2Blocks.append(DraftV2Block(kind: .gallery, mediaURL: "")) } label: {
                        Label("Thêm MediaGallery (12)", systemImage: "photo.on.rectangle.angled")
                    }
                    Button { v2Blocks.append(DraftV2Block(kind: .separator)) } label: {
                        Label("Thêm Separator (14)", systemImage: "minus")
                    }
                    Button { v2Blocks.append(DraftV2Block(kind: .actionRow)) } label: {
                        Label("Thêm ActionRow + Buttons (1+2)", systemImage: "rectangle.grid.2x2")
                    }
                } label: {
                    Label("Thêm khối thành phần V2", systemImage: "plus.circle.fill")
                }
            }

            Section("Xem trước trực tiếp") {
                MessageComponentsRendererView(components: builtV2Components) { _, _ in }
                    .environmentObject(vault)
                    .padding(.vertical, 4)
            }

            if let err = studioError {
                Section {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            Section {
                Button {
                    Task { await sendV2Now() }
                } label: {
                    HStack {
                        Image(systemName: "paperplane.fill")
                        Text(isSendingV2 ? "Đang gửi Components V2..." : "Gửi ngay với flags: 32768")
                        Spacer()
                        if isSendingV2 { ProgressView() }
                    }
                }
                .disabled(isSendingV2 || builtV2Components.isEmpty)
            }
        }
    }

    @ViewBuilder
    private func v2BlockEditor(idx: Int) -> some View {
        let block = v2Blocks[idx]
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(block.kind.rawValue)
                    .font(.caption.weight(.bold))
                    .foregroundColor(vault.accentColor)
                Spacer()
                Button(role: .destructive) {
                    v2Blocks.remove(at: idx)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }

            switch block.kind {
            case .textDisplay:
                HStack {
                    TextField("Nội dung Markdown...", text: $v2Blocks[idx].text)
                    Button {
                        emojiPickerTarget = .v2Block(idx)
                    } label: {
                        Image(systemName: "face.smiling")
                            .foregroundColor(vault.accentColor)
                    }
                    .buttonStyle(.borderless)
                }
            case .section:
                TextField("Nội dung đoạn...", text: $v2Blocks[idx].text)
                TextField("URL Thumbnail (nếu trống tự chuyển TextDisplay)...", text: $v2Blocks[idx].mediaURL)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
            case .gallery:
                TextField("URL ảnh (nhiều URL cách bởi dấu phẩy)...", text: $v2Blocks[idx].mediaURL)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
            case .separator:
                Toggle("Hiển thị đường kẻ", isOn: $v2Blocks[idx].divider)
                Toggle("Khoảng cách lớn", isOn: $v2Blocks[idx].largeSpacing)
            case .actionRow:
                ForEach(Array(block.buttons.enumerated()), id: \.element.id) { bIdx, _ in
                    buttonEditorCard(binding: $v2Blocks[idx].buttons[bIdx]) {
                        v2Blocks[idx].buttons.remove(at: bIdx)
                    }
                }
                if block.buttons.count < 5 {
                    Button {
                        v2Blocks[idx].buttons.append(DraftButton())
                    } label: {
                        Label("Thêm nút trong hàng", systemImage: "plus")
                            .font(.caption)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func buttonEditorCard(binding: Binding<DraftButton>, onDelete: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Nhãn nút...", text: binding.label)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "minus.circle.fill")
                }
                .buttonStyle(.borderless)
            }

            Picker("Kiểu nút", selection: binding.style) {
                Text("Primary (Xanh)").tag(1)
                Text("Secondary (Xám)").tag(2)
                Text("Success (Lục)").tag(3)
                Text("Danger (Đỏ)").tag(4)
                Text("Link URL").tag(5)
            }

            if binding.wrappedValue.style == 5 {
                TextField("https://...", text: binding.url)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
            } else {
                TextField("Custom ID", text: binding.customId)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                TextField("Auto-Reply khi người dùng bấm (tuỳ chọn)", text: binding.autoReply)
                Toggle("Trả lời riêng tư (Ephemeral)", isOn: binding.ephemeral)
            }
        }
        .padding(.vertical, 4)
    }

    private func colorPresetRow(selectedHex: Binding<String>) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(BotVaultStore.accentPresets, id: \.hex) { preset in
                    Button {
                        selectedHex.wrappedValue = preset.hex
                    } label: {
                        Circle()
                            .fill(Color(hex: preset.hex))
                            .frame(width: 26, height: 26)
                            .overlay(
                                Circle().strokeBorder(Color.white, lineWidth: selectedHex.wrappedValue == preset.hex ? 2.5 : 0)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func buildButtonComponent(from draft: DraftButton) -> DiscordComponent? {
        let lbl = draft.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lbl.isEmpty else { return nil }
        if draft.style == 5 {
            let u = draft.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !u.isEmpty else { return nil }
            return DiscordComponent(type: 2, style: 5, label: lbl, url: u)
        } else {
            let cid = draft.customId.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalCid = cid.isEmpty ? "dbc_\(draft.id.uuidString.prefix(8))" : cid
            if !draft.autoReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                vault.upsertAutoReply(customId: finalCid, replyContent: draft.autoReply, ephemeral: draft.ephemeral)
            }
            return DiscordComponent(type: 2, customId: finalCid, style: draft.style, label: lbl)
        }
    }

    private var builtV2Components: [DiscordComponent] {
        var children: [DiscordComponent] = []
        for b in v2Blocks {
            switch b.kind {
            case .textDisplay:
                let t = b.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty {
                    children.append(DiscordComponent(type: 10, content: t))
                }
            case .section:
                let t = b.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let thumb = b.mediaURL.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty {
                    let td = DiscordComponent(type: 10, content: t)
                    if !thumb.isEmpty {
                        let acc = DiscordComponent(type: 11, media: DiscordUnfurledMediaItem(url: thumb))
                        children.append(DiscordComponent(type: 9, components: [td], accessory: acc))
                    } else {
                        children.append(td)
                    }
                }
            case .gallery:
                let urls = b.mediaURL
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                let items = urls.map { DiscordMediaGalleryItem(media: DiscordUnfurledMediaItem(url: $0)) }
                if !items.isEmpty {
                    children.append(DiscordComponent(type: 12, items: items))
                }
            case .separator:
                children.append(DiscordComponent(type: 14, divider: b.divider, spacing: b.largeSpacing ? 2 : 1))
            case .actionRow:
                let btns = b.buttons.compactMap { buildButtonComponent(from: $0) }
                if !btns.isEmpty {
                    children.append(DiscordComponent(type: 1, components: btns))
                }
            }
        }
        guard !children.isEmpty else { return [] }
        let cleanedHex = v2HexColor.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let colorInt = Int(cleanedHex, radix: 16)
        let container = DiscordComponent(
            type: 17,
            spoiler: v2Spoiler ? true : nil,
            accentColor: colorInt,
            components: children
        )
        return [container]
    }

    private func applyV1() {
        let t = embedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let d = embedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let f = embedFooter.trimmingCharacters(in: .whitespacesAndNewlines)
        let img = embedImageURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let th = embedThumbnailURL.trimmingCharacters(in: .whitespacesAndNewlines)

        var embed: DiscordEmbed? = nil
        if !t.isEmpty || !d.isEmpty || !img.isEmpty {
            let cleanedHex = embedHexColor.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            let colorInt = Int(cleanedHex, radix: 16) ?? 0x5865F2
            embed = DiscordEmbed(
                title: t.isEmpty ? nil : t,
                description: d.isEmpty ? nil : d,
                url: nil,
                color: colorInt,
                timestamp: nil,
                footer: f.isEmpty ? nil : DiscordEmbedFooter(text: f, iconUrl: nil),
                image: img.isEmpty ? nil : DiscordEmbedMedia(url: img),
                thumbnail: th.isEmpty ? nil : DiscordEmbedMedia(url: th),
                author: nil,
                fields: nil
            )
        }

        let builtBtns = v1Buttons.compactMap { buildButtonComponent(from: $0) }
        let row: [DiscordComponent] = builtBtns.isEmpty ? [] : [DiscordComponent(type: 1, components: builtBtns)]
        onAttachV1(embed, row)
        dismiss()
    }

    private func sendV2Now() async {
        let comps = builtV2Components
        guard !comps.isEmpty else { return }
        isSendingV2 = true
        studioError = nil
        defer { isSendingV2 = false }
        do {
            try await onSendV2(comps, 32_768)
            dismiss()
        } catch {
            studioError = error.localizedDescription
        }
    }
}
