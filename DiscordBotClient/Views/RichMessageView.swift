import SwiftUI
import UIKit
import ImageIO

// MARK: - Animated Emoji Cache & UIImageView Renderer

final class EmojiImageCache {
    static let shared = EmojiImageCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 400
    }

    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func store(_ image: UIImage, for key: String) {
        cache.setObject(image, forKey: key as NSString)
    }

    static func decodeImage(from data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return UIImage(data: data)
        }
        let count = CGImageSourceGetCount(source)
        if count <= 1 {
            return UIImage(data: data)
        }
        var frames: [UIImage] = []
        var totalDuration: Double = 0
        for idx in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(source, idx, nil) else { continue }
            frames.append(UIImage(cgImage: cg))
            totalDuration += frameDuration(source: source, index: idx)
        }
        if frames.isEmpty { return UIImage(data: data) }
        if totalDuration <= 0.01 { totalDuration = Double(frames.count) * 0.1 }
        return UIImage.animatedImage(with: frames, duration: totalDuration) ?? frames.first
    }

    private static func frameDuration(source: CGImageSource, index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else {
            return 0.1
        }
        if let gifDict = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
            let unclamped = gifDict[kCGImagePropertyGIFUnclampedDelayTime] as? Double
            let clamped = gifDict[kCGImagePropertyGIFDelayTime] as? Double
            let delay = unclamped ?? clamped ?? 0.1
            return delay < 0.02 ? 0.1 : delay
        }
        if let webpDict = props[kCGImagePropertyWebPDictionary] as? [CFString: Any] {
            let unclamped = webpDict[kCGImagePropertyWebPUnclampedDelayTime] as? Double
            let clamped = webpDict[kCGImagePropertyWebPDelayTime] as? Double
            let delay = unclamped ?? clamped ?? 0.1
            return delay < 0.02 ? 0.1 : delay
        }
        return 0.1
    }
}

private final class FixedSizeEmojiHostView: UIView {
    let imageView = UIImageView()
    var targetSize: CGFloat = 22

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        CGSize(width: targetSize, height: targetSize)
    }
}

struct AnimatedEmojiImageView: View {
    let url: URL?
    let size: CGFloat

    @State private var loadedImage: UIImage?

    var body: some View {
        Group {
            if let img = loadedImage {
                EmojiUIImageRepresentable(image: img, size: size)
                    .frame(width: size, height: size)
            } else {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: size, height: size)
            }
        }
        .task(id: url?.absoluteString ?? "") {
            await loadIfNeeded()
        }
    }

    private func loadIfNeeded() async {
        guard let url = url else { return }
        let key = url.absoluteString
        if let cached = EmojiImageCache.shared.image(forKey: key) {
            loadedImage = cached
            return
        }
        var req = URLRequest(url: url)
        req.cachePolicy = .returnCacheDataElseLoad
        req.timeoutInterval = 15
        if let (data, _) = try? await URLSession.shared.data(for: req),
           let decoded = EmojiImageCache.decodeImage(from: data) {
            EmojiImageCache.shared.store(decoded, forKey: key)
            await MainActor.run {
                loadedImage = decoded
            }
        }
    }
}

private struct EmojiUIImageRepresentable: UIViewRepresentable {
    let image: UIImage
    let size: CGFloat

    func makeUIView(context: Context) -> FixedSizeEmojiHostView {
        let v = FixedSizeEmojiHostView()
        v.targetSize = size
        v.imageView.image = image
        return v
    }

    func updateUIView(_ uiView: FixedSizeEmojiHostView, context: Context) {
        uiView.targetSize = size
        if uiView.imageView.image !== image {
            uiView.imageView.image = image
        }
        uiView.invalidateIntrinsicContentSize()
    }
}

// MARK: - Rich Message Parsing & Inspector

struct ParsedEmojiInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let animated: Bool
    let cdnURL: URL

    var rawTag: String {
        animated ? "<a:\(name):\(id)>" : "<:\(name):\(id)>"
    }

    var hyperlinkMarkdown: String {
        if animated {
            return "[\(name)](https://cdn.discordapp.com/emojis/\(id).gif?size=48&name=\(name))"
        }
        return "[\(name)](https://cdn.discordapp.com/emojis/\(id).webp?size=48&name=\(name)&lossless=true)"
    }
}

private enum RichToken: Identifiable {
    case text(String, String)
    case link(String, String, URL)
    case code(String, String)
    case emoji(String, ParsedEmojiInfo)

    var id: String {
        switch self {
        case .text(let id, _): return id
        case .link(let id, _, _): return id
        case .code(let id, _): return id
        case .emoji(let id, _): return id
        }
    }
}

struct RichMessageContentView: View {
    let rawContent: String
    let isEdited: Bool
    let guild: DiscordGuild?
    let mentions: [DiscordUser]?
    let members: [DiscordMember]

    @EnvironmentObject private var vault: BotVaultStore
    @State private var inspectedEmoji: ParsedEmojiInfo?

    var body: some View {
        let tokens = tokenize(rawContent)
        let emojiOnlyCount = countOnlyEmojis(tokens)

        VStack(alignment: .leading, spacing: 4) {
            if emojiOnlyCount > 0 && emojiOnlyCount <= 5 {
                HStack(spacing: 6) {
                    ForEach(tokens) { tok in
                        if case .emoji(_, let info) = tok {
                            Button {
                                inspectedEmoji = info
                            } label: {
                                AnimatedEmojiImageView(url: info.cdnURL, size: 44)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if isEdited {
                        Text("(đã sửa)")
                            .font(.caption2)
                            .foregroundColor(vault.secondaryTextColor)
                    }
                }
            } else {
                InlineFlowTokenLayout(tokens: tokens, isEdited: isEdited, onTapEmoji: { info in
                    inspectedEmoji = info
                })
            }
        }
        .sheet(item: $inspectedEmoji) { info in
            EmojiInspectorSheet(info: info)
                .environmentObject(vault)
        }
    }

    private func countOnlyEmojis(_ tokens: [RichToken]) -> Int {
        var count = 0
        for t in tokens {
            switch t {
            case .emoji:
                count += 1
            case .text(_, let s):
                if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return 0
                }
            default:
                return 0
            }
        }
        return count
    }

    private func tokenize(_ raw: String) -> [RichToken] {
        let mentionCleaned = DiscordTextFormatter.renderCleanText(
            raw,
            guild: guild,
            mentions: mentions,
            members: members
        )

        // Match: ```code```, `inline`, [name](cdn emoji), <a?:name:id>, bare cdn emoji URL, or [text](https://...)
        let pattern = #"```[\s\S]*?```|`[^`\n]+`|\[([^\]]+)\]\((https?://(?:cdn\.discordapp\.com|media\.discordapp\.net)/emojis/(\d+)\.(webp|png|gif)[^\s)]*)\)|<(a?):([A-Za-z0-9_]+):(\d+)>|(https?://(?:cdn\.discordapp\.com|media\.discordapp\.net)/emojis/(\d+)\.(webp|png|gif)(?:\?[^\s]+)?)|\[([^\]]+)\]\((https?://[^\s)]+)\)|(https?://[^\s<>]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [.text("t0", mentionCleaned)]
        }

        var result: [RichToken] = []
        var cursor = mentionCleaned.startIndex
        let matches = regex.matches(in: mentionCleaned, range: NSRange(mentionCleaned.startIndex..., in: mentionCleaned))
        var seq = 0

        for m in matches {
            guard let fullRange = Range(m.range, in: mentionCleaned) else { continue }
            if cursor < fullRange.lowerBound {
                let prefix = String(mentionCleaned[cursor..<fullRange.lowerBound])
                appendSplitText(prefix, seq: &seq, into: &result)
            }

            let matched = String(mentionCleaned[fullRange])
            if matched.hasPrefix("```") || matched.hasPrefix("`") {
                let stripped = matched.hasPrefix("```")
                    ? String(matched.dropFirst(3).dropLast(matched.hasSuffix("```") ? 3 : 0)).trimmingCharacters(in: .whitespacesAndNewlines)
                    : String(matched.dropFirst().dropLast(matched.hasSuffix("`") ? 1 : 0))
                result.append(.code("c\(seq)", stripped))
                seq += 1
            } else if let nameR = Range(m.range(at: 1), in: mentionCleaned),
                      let urlR = Range(m.range(at: 2), in: mentionCleaned),
                      let idR = Range(m.range(at: 3), in: mentionCleaned),
                      let extR = Range(m.range(at: 4), in: mentionCleaned),
                      let cdnURL = URL(string: String(mentionCleaned[urlR])) {
                let anim = String(mentionCleaned[extR]).lowercased() == "gif"
                let info = ParsedEmojiInfo(id: String(mentionCleaned[idR]), name: String(mentionCleaned[nameR]), animated: anim, cdnURL: cdnURL)
                result.append(.emoji("e\(seq)", info))
                seq += 1
            } else if let aR = Range(m.range(at: 5), in: mentionCleaned),
                      let nameR = Range(m.range(at: 6), in: mentionCleaned),
                      let idR = Range(m.range(at: 7), in: mentionCleaned) {
                let anim = String(mentionCleaned[aR]) == "a"
                let eid = String(mentionCleaned[idR])
                let ename = String(mentionCleaned[nameR])
                let urlStr = anim
                    ? "https://cdn.discordapp.com/emojis/\(eid).gif?size=96"
                    : "https://cdn.discordapp.com/emojis/\(eid).webp?size=96&lossless=true"
                if let cdnURL = URL(string: urlStr) {
                    let info = ParsedEmojiInfo(id: eid, name: ename, animated: anim, cdnURL: cdnURL)
                    result.append(.emoji("e\(seq)", info))
                    seq += 1
                }
            } else if let urlR = Range(m.range(at: 8), in: mentionCleaned),
                      let idR = Range(m.range(at: 9), in: mentionCleaned),
                      let extR = Range(m.range(at: 10), in: mentionCleaned),
                      let cdnURL = URL(string: String(mentionCleaned[urlR])) {
                let anim = String(mentionCleaned[extR]).lowercased() == "gif"
                let eid = String(mentionCleaned[idR])
                let info = ParsedEmojiInfo(id: eid, name: "emoji", animated: anim, cdnURL: cdnURL)
                result.append(.emoji("e\(seq)", info))
                seq += 1
            } else if let textR = Range(m.range(at: 11), in: mentionCleaned),
                      let urlR = Range(m.range(at: 12), in: mentionCleaned),
                      let linkURL = URL(string: String(mentionCleaned[urlR])) {
                result.append(.link("l\(seq)", String(mentionCleaned[textR]), linkURL))
                seq += 1
            } else if let urlR = Range(m.range(at: 13), in: mentionCleaned),
                      let linkURL = URL(string: String(mentionCleaned[urlR])) {
                result.append(.link("l\(seq)", String(mentionCleaned[urlR]), linkURL))
                seq += 1
            }

            cursor = fullRange.upperBound
        }

        if cursor < mentionCleaned.endIndex {
            let tail = String(mentionCleaned[cursor..<mentionCleaned.endIndex])
            appendSplitText(tail, seq: &seq, into: &result)
        }
        return result
    }

    private func appendSplitText(_ chunk: String, seq: inout Int, into result: inout [RichToken]) {
        // Split words preserving spaces/newlines cleanly for smooth wrapping around inline emojis
        let lines = chunk.split(separator: "\n", omittingEmptySubsequences: false)
        for (lIdx, line) in lines.enumerated() {
            let words = line.split(separator: " ", omittingEmptySubsequences: false)
            for (wIdx, w) in words.enumerated() {
                let s = String(w) + (wIdx < words.count - 1 ? " " : "")
                if !s.isEmpty {
                    result.append(.text("t\(seq)", s))
                    seq += 1
                }
            }
            if lIdx < lines.count - 1 {
                result.append(.text("nl\(seq)", "\n"))
                seq += 1
            }
        }
    }
}

private struct InlineFlowTokenLayout: View {
    let tokens: [RichToken]
    let isEdited: Bool
    let onTapEmoji: (ParsedEmojiInfo) -> Void

    @EnvironmentObject private var vault: BotVaultStore
    @State private var availableWidth: CGFloat = 260

    var body: some View {
        // Fast path: pure text + links (no inline emojis or code) -> native selectable Text
        if !tokens.contains(where: { if case .emoji = $0 { return true }; if case .code = $0 { return true }; return false }) {
            pureTextView
        } else {
            wrappingTokensView
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear {
                                if geo.size.width > 40 { availableWidth = geo.size.width }
                            }
                            .onChange(of: geo.size.width) { w in
                                if w > 40 { availableWidth = w }
                            }
                    }
                )
        }
    }

    private var pureTextView: some View {
        var combined = AttributedString()
        for t in tokens {
            switch t {
            case .text(_, let s):
                var part = AttributedString(s)
                part.foregroundColor = vault.primaryTextColor
                combined += part
            case .link(_, let title, let url):
                var part = AttributedString(title)
                part.link = url
                part.foregroundColor = vault.accentColor
                part.underlineStyle = .single
                combined += part
            default:
                break
            }
        }
        if isEdited {
            var ed = AttributedString(" (đã sửa)")
            ed.foregroundColor = vault.secondaryTextColor
            ed.font = .caption2
            combined += ed
        }
        return Text(combined)
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var wrappingTokensView: some View {
        var width: CGFloat = 0
        var height: CGFloat = 0
        let allItems = tokens + (isEdited ? [.text("edited-suffix", " (đã sửa)")] : [])

        return ZStack(alignment: .topLeading) {
            ForEach(Array(allItems.enumerated()), id: \.element.id) { idx, token in
                tokenCell(token)
                    .alignmentGuide(.leading) { d in
                        if case .text(_, let s) = token, s == "\n" {
                            width = 0
                            height -= 20
                            return 0
                        }
                        if width != 0 && abs(width - d.width) > availableWidth {
                            width = 0
                            height -= d.height + 2
                        }
                        let res = width
                        if idx == allItems.count - 1 {
                            width = 0
                        } else {
                            width -= d.width
                        }
                        return res
                    }
                    .alignmentGuide(.top) { d in
                        let res = height
                        if idx == allItems.count - 1 {
                            height = 0
                        }
                        return res
                    }
            }
        }
    }

    @ViewBuilder
    private func tokenCell(_ token: RichToken) -> some View {
        switch token {
        case .text(let id, let str):
            if str == "\n" {
                Color.clear.frame(width: 1, height: 1)
            } else {
                Text(str)
                    .font(id == "edited-suffix" ? .caption2 : .subheadline)
                    .foregroundColor(id == "edited-suffix" ? vault.secondaryTextColor : vault.primaryTextColor)
            }
        case .link(_, let label, let url):
            Button {
                UIApplication.shared.open(url)
            } label: {
                Text(label)
                    .font(.subheadline)
                    .foregroundColor(vault.accentColor)
                    .underline()
            }
            .buttonStyle(.plain)
        case .code(_, let code):
            Text(code)
                .font(.caption.monospaced())
                .foregroundColor(vault.primaryTextColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(vault.elevatedSurfaceColor)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        case .emoji(_, let info):
            Button {
                onTapEmoji(info)
            } label: {
                AnimatedEmojiImageView(url: info.cdnURL, size: 22)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 1)
        }
    }
}

struct EmojiInspectorSheet: View {
    let info: ParsedEmojiInfo
    @EnvironmentObject private var vault: BotVaultStore
    @Environment(\.dismiss) private var dismiss
    @State private var copiedLabel: String?

    var body: some View {
        NavigationView {
            VStack(spacing: 18) {
                AnimatedEmojiImageView(url: info.cdnURL, size: 96)
                    .padding(16)
                    .background(vault.surfaceColor)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                VStack(spacing: 4) {
                    Text(":\(info.name):")
                        .font(.headline)
                        .foregroundColor(vault.primaryTextColor)
                    Text("ID: \(info.id) • \(info.animated ? "Animated GIF" : "Static")")
                        .font(.caption.monospaced())
                        .foregroundColor(vault.secondaryTextColor)
                }

                VStack(spacing: 10) {
                    copyButton(title: "Sao chép Emoji gốc (\(info.rawTag))", icon: "face.smiling", value: info.rawTag)
                    copyButton(title: "Sao chép Hyperlink [name](cdn...)", icon: "link", value: info.hyperlinkMarkdown)
                    copyButton(title: "Sao chép URL CDN", icon: "globe", value: info.cdnURL.absoluteString)
                }
                .padding(.horizontal, 16)

                if let copied = copiedLabel {
                    Text(copied)
                        .font(.caption)
                        .foregroundColor(.green)
                }

                Spacer()
            }
            .padding(.top, 24)
            .background(vault.backgroundColor.ignoresSafeArea())
            .navigationTitle("Chi tiết Emoji")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Đóng") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func copyButton(title: String, icon: String, value: String) -> some View {
        Button {
            UIPasteboard.general.string = value
            copiedLabel = "Đã sao chép vào Clipboard."
        } label: {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(vault.accentColor)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(vault.primaryTextColor)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "doc.on.doc")
                    .font(.caption)
                    .foregroundColor(vault.secondaryTextColor)
            }
            .padding(12)
            .background(vault.surfaceColor)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Components V1 & V2 Renderer

struct MessageComponentsRendererView: View {
    let components: [DiscordComponent]
    let onTapImage: (URL, String) -> Void

    @EnvironmentObject private var vault: BotVaultStore
    @State private var revealedSpoilers: Set<String> = []
    @State private var tappedNotice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(components) { comp in
                renderComponent(comp)
            }
            if let note = tappedNotice {
                Text(note)
                    .font(.caption2)
                    .foregroundColor(vault.accentColor)
            }
        }
    }

    @ViewBuilder
    private func renderComponent(_ comp: DiscordComponent) -> some View {
        switch comp.type {
        case 1: // ActionRow
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(comp.components ?? []) { child in
                        AnyView(renderComponent(child))
                    }
                }
            }

        case 2: // Button
            buttonView(comp)

        case 3: // StringSelect preview pill
            HStack {
                Image(systemName: "list.bullet.rectangle")
                    .font(.caption)
                    .foregroundColor(vault.secondaryTextColor)
                Text(comp.placeholder ?? "Chọn một tùy chọn...")
                    .font(.caption)
                    .foregroundColor(vault.secondaryTextColor)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundColor(vault.secondaryTextColor)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(vault.surfaceColor)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(vault.dividerColor, lineWidth: 1))

        case 9: // Section (TextDisplay children + Thumbnail/Button accessory)
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(comp.components ?? []) { child in
                        AnyView(renderComponent(child))
                    }
                }
                Spacer(minLength: 4)
                if let acc = comp.accessory {
                    AnyView(renderComponent(acc))
                }
            }

        case 10: // TextDisplay
            if let text = comp.content, !text.isEmpty {
                RichMessageContentView(
                    rawContent: text,
                    isEdited: false,
                    guild: nil,
                    mentions: nil,
                    members: []
                )
            }

        case 11: // Thumbnail
            if let urlStr = comp.media?.url, let url = URL(string: urlStr) {
                Button {
                    onTapImage(url, comp.description ?? "Thumbnail")
                } label: {
                    AsyncImage(url: url) { ph in
                        if case .success(let img) = ph {
                            img.resizable().scaledToFill()
                        } else {
                            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(vault.elevatedSurfaceColor)
                        }
                    }
                    .frame(width: 68, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }

        case 12: // MediaGallery
            let items = comp.items ?? []
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], spacing: 6) {
                ForEach(items) { item in
                    if let url = URL(string: item.media.url) {
                        Button {
                            onTapImage(url, item.description ?? "Media")
                        } label: {
                            AsyncImage(url: url) { ph in
                                if case .success(let img) = ph {
                                    img.resizable()
                                        .scaledToFill()
                                        .frame(height: 110)
                                        .clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                } else {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(vault.elevatedSurfaceColor)
                                        .frame(height: 110)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

        case 13: // File
            if let fUrlStr = comp.file?.url, let url = URL(string: fUrlStr) {
                Button {
                    UIApplication.shared.open(url)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.fill")
                            .foregroundColor(vault.accentColor)
                        Text(url.lastPathComponent.isEmpty ? fUrlStr : url.lastPathComponent)
                            .font(.caption.weight(.medium))
                            .foregroundColor(vault.primaryTextColor)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
                            .foregroundColor(vault.secondaryTextColor)
                    }
                    .padding(10)
                    .background(vault.elevatedSurfaceColor)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }

        case 14: // Separator
            if comp.divider != false {
                Divider()
                    .background(vault.dividerColor)
                    .padding(.vertical, (comp.spacing ?? 1) > 1 ? 6 : 2)
            } else {
                Spacer().frame(height: (comp.spacing ?? 1) > 1 ? 14 : 6)
            }

        case 17: // Container
            let isSpoiler = (comp.spoiler == true) && !revealedSpoilers.contains(comp.id)
            let barColor: Color = {
                guard let c = comp.accentColor, c != 0 else { return vault.accentColor }
                return Color(
                    red: Double((c >> 16) & 0xFF) / 255.0,
                    green: Double((c >> 8) & 0xFF) / 255.0,
                    blue: Double(c & 0xFF) / 255.0
                )
            }()

            HStack(spacing: 0) {
                Rectangle()
                    .fill(barColor)
                    .frame(width: 4)

                VStack(alignment: .leading, spacing: 8) {
                    if isSpoiler {
                        Button {
                            revealedSpoilers.insert(comp.id)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "eye.slash.fill")
                                Text("Nội dung ẩn (Chạm để xem)")
                                    .font(.caption.weight(.semibold))
                            }
                            .foregroundColor(vault.secondaryTextColor)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                    } else {
                        ForEach(comp.components ?? []) { child in
                            AnyView(renderComponent(child))
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(vault.surfaceColor)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(vault.dividerColor, lineWidth: 1))

        default:
            EmptyView()
        }
    }

    private func buttonView(_ btn: DiscordComponent) -> some View {
        let style = btn.style ?? 1
        let bg: Color = {
            switch style {
            case 1: return Color(red: 0.345, green: 0.396, blue: 0.949)
            case 3: return Color(red: 0.137, green: 0.549, blue: 0.314)
            case 4: return Color(red: 0.855, green: 0.216, blue: 0.235)
            default: return vault.elevatedSurfaceColor
            }
        }()

        return Button {
            if style == 5, let uStr = btn.url, let url = URL(string: uStr) {
                UIApplication.shared.open(url)
            } else if let cid = btn.customId {
                if let rule = vault.buttonAutoReplies.first(where: { $0.customId == cid }) {
                    tappedNotice = "Auto-Reply (\(cid)): \(rule.replyContent)"
                } else {
                    tappedNotice = "Interactive Button: \(cid)"
                }
            }
        } label: {
            HStack(spacing: 5) {
                if let eURL = btn.emoji?.imageURL {
                    AnimatedEmojiImageView(url: eURL, size: 16)
                } else if let eName = btn.emoji?.name, !eName.isEmpty {
                    Text(eName).font(.caption)
                }
                if let lbl = btn.label, !lbl.isEmpty {
                    Text(lbl)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white)
                }
                if style == 5 {
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.9))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(bg)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity((btn.disabled ?? false) ? 0.5 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(btn.disabled ?? false)
    }
}
