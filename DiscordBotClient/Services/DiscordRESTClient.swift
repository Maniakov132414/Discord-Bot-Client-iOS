import Foundation

enum DiscordAPIError: LocalizedError {
    case invalidURL
    case httpError(Int, String)
    case decodingError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "URL không hợp lệ."
        case .httpError(let code, let msg):
            return "Lỗi Discord API [\(code)]: \(msg)"
        case .decodingError(let msg):
            return "Lỗi giải mã dữ liệu: \(msg)"
        }
    }
}

private struct ApplicationEmojisEnvelope: Decodable {
    let items: [DiscordEmoji]
}

final class DiscordRESTClient {
    static let shared = DiscordRESTClient()

    private let baseURL = "https://discord.com/api/v10"
    private let userAgent = "DiscordBot (https://github.com/cocconne/discord-bot-client-web, 2.1.0)"
    private let session: URLSession
    private let decoder = JSONDecoder()

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 25
        cfg.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: cfg)
    }

    private func makeRequest(
        path: String,
        method: String = "GET",
        token: String,
        contentType: String? = "application/json",
        body: Data? = nil
    ) throws -> URLRequest {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw DiscordAPIError.invalidURL
        }
        let clean = BotVaultStore.normalizeToken(token)
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bot \(clean)", forHTTPHeaderField: "Authorization")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let ct = contentType {
            req.setValue(ct, forHTTPHeaderField: "Content-Type")
        }
        req.httpBody = body
        return req
    }

    private func executeRaw(_ req: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw DiscordAPIError.httpError(0, "Không có phản hồi HTTP")
        }
        if !(200..<300).contains(http.statusCode) {
            let errObj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let msg = (errObj?["message"] as? String) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw DiscordAPIError.httpError(http.statusCode, msg)
        }
        return (data, http.statusCode)
    }

    private func execute<T: Decodable>(_ req: URLRequest, as type: T.Type) async throws -> T {
        let (data, _) = try await executeRaw(req)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw DiscordAPIError.decodingError(error.localizedDescription)
        }
    }

    // MARK: - Bot, Emojis & Guilds

    func fetchCurrentApplication(token: String) async throws -> DiscordApplication {
        let req = try makeRequest(path: "/applications/@me?with_counts=true", token: token)
        return try await execute(req, as: DiscordApplication.self)
    }

    func fetchApplicationEmojis(applicationId: String, token: String) async throws -> [DiscordEmoji] {
        let req = try makeRequest(path: "/applications/\(applicationId)/emojis", token: token)
        let env = try await execute(req, as: ApplicationEmojisEnvelope.self)
        return env.items
    }

    func fetchCurrentUser(token: String) async throws -> DiscordUser {
        let req = try makeRequest(path: "/users/@me", token: token)
        return try await execute(req, as: DiscordUser.self)
    }

    func fetchGuildChannels(guildId: String, token: String) async throws -> [DiscordChannel] {
        let req = try makeRequest(path: "/guilds/\(guildId)/channels", token: token)
        return try await execute(req, as: [DiscordChannel].self)
    }

    func fetchGuildRoles(guildId: String, token: String) async throws -> [DiscordRole] {
        let req = try makeRequest(path: "/guilds/\(guildId)/roles", token: token)
        return try await execute(req, as: [DiscordRole].self)
    }

    func fetchGuildEmojis(guildId: String, token: String) async throws -> [DiscordEmoji] {
        let req = try makeRequest(path: "/guilds/\(guildId)/emojis", token: token)
        return try await execute(req, as: [DiscordEmoji].self)
    }

    func fetchGuildMembers(guildId: String, limit: Int = 200, query: String? = nil, token: String) async throws -> [DiscordMember] {
        let path: String
        if let q = query?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty {
            let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
            path = "/guilds/\(guildId)/members/search?query=\(encoded)&limit=\(min(limit, 100))"
        } else {
            path = "/guilds/\(guildId)/members?limit=\(min(limit, 1000))"
        }
        let req = try makeRequest(path: path, token: token)
        return try await execute(req, as: [DiscordMember].self)
    }

    // MARK: - Messages & Components V2

    func fetchMessages(channelId: String, before: String? = nil, limit: Int = 50, token: String) async throws -> [DiscordMessage] {
        var path = "/channels/\(channelId)/messages?limit=\(min(max(limit, 1), 100))"
        if let before = before, !before.isEmpty {
            path += "&before=\(before)"
        }
        let req = try makeRequest(path: path, token: token)
        let list = try await execute(req, as: [DiscordMessage].self)
        return list.reversed()
    }

    func sendMessage(
        channelId: String,
        content: String,
        embeds: [DiscordEmbed] = [],
        components: [DiscordComponent] = [],
        flags: Int? = nil,
        replyToMessageId: String? = nil,
        attachments: [MediaUploadItem] = [],
        token: String
    ) async throws -> DiscordMessage {
        let isV2 = ((flags ?? 0) & 32_768) != 0
        var payload: [String: Any] = [:]

        if !isV2 {
            payload["content"] = content
            if !embeds.isEmpty,
               let embData = try? JSONEncoder().encode(embeds),
               let embArr = try? JSONSerialization.jsonObject(with: embData) {
                payload["embeds"] = embArr
            }
        }
        if let flags = flags, flags != 0 {
            payload["flags"] = flags
        }
        let mappedComponents = components.compactMap { $0.toAPIDictionary() }
        if !mappedComponents.isEmpty {
            payload["components"] = mappedComponents
        }
        if let replyId = replyToMessageId, !replyId.isEmpty {
            payload["message_reference"] = [
                "message_id": replyId,
                "fail_if_not_exists": false
            ]
        }

        if attachments.isEmpty {
            let body = try JSONSerialization.data(withJSONObject: payload)
            let req = try makeRequest(path: "/channels/\(channelId)/messages", method: "POST", token: token, body: body)
            return try await execute(req, as: DiscordMessage.self)
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        var attMeta: [[String: Any]] = []
        for (idx, item) in attachments.enumerated() {
            attMeta.append(["id": idx, "filename": item.filename])
        }
        payload["attachments"] = attMeta
        let payloadData = try JSONSerialization.data(withJSONObject: payload)

        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"payload_json\"\r\n".utf8))
        body.append(Data("Content-Type: application/json\r\n\r\n".utf8))
        body.append(payloadData)
        body.append(Data("\r\n".utf8))

        for (idx, item) in attachments.enumerated() {
            let safeName = item.filename.replacingOccurrences(of: "\"", with: "_")
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"files[\(idx)]\"; filename=\"\(safeName)\"\r\n".utf8))
            body.append(Data("Content-Type: \(item.mimeType)\r\n\r\n".utf8))
            body.append(item.data)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))

        let req = try makeRequest(
            path: "/channels/\(channelId)/messages",
            method: "POST",
            token: token,
            contentType: "multipart/form-data; boundary=\(boundary)",
            body: body
        )
        return try await execute(req, as: DiscordMessage.self)
    }

    func editMessage(
        channelId: String,
        messageId: String,
        content: String?,
        embeds: [DiscordEmbed]?,
        components: [DiscordComponent]? = nil,
        flags: Int? = nil,
        token: String
    ) async throws -> DiscordMessage {
        let isV2 = ((flags ?? 0) & 32_768) != 0
        var payload: [String: Any] = [:]

        if !isV2 {
            if let content = content {
                payload["content"] = content
            }
            if let embeds = embeds,
               let embData = try? JSONEncoder().encode(embeds),
               let embArr = try? JSONSerialization.jsonObject(with: embData) {
                payload["embeds"] = embArr
            }
        }
        if let flags = flags, flags != 0 {
            payload["flags"] = flags
        }
        if let components = components {
            payload["components"] = components.compactMap { $0.toAPIDictionary() }
        }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let req = try makeRequest(path: "/channels/\(channelId)/messages/\(messageId)", method: "PATCH", token: token, body: body)
        return try await execute(req, as: DiscordMessage.self)
    }

    func respondToInteraction(
        interactionId: String,
        interactionToken: String,
        type: Int,
        content: String? = nil,
        ephemeral: Bool = false,
        token: String
    ) async throws {
        var payload: [String: Any] = ["type": type]
        if type == 4 {
            var data: [String: Any] = ["content": content ?? ""]
            if ephemeral {
                data["flags"] = 64
            }
            payload["data"] = data
        }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let req = try makeRequest(
            path: "/interactions/\(interactionId)/\(interactionToken)/callback",
            method: "POST",
            token: token,
            body: body
        )
        _ = try await executeRaw(req)
    }

    func deleteMessage(channelId: String, messageId: String, token: String) async throws {
        let req = try makeRequest(path: "/channels/\(channelId)/messages/\(messageId)", method: "DELETE", token: token)
        _ = try await executeRaw(req)
    }

    func bulkDeleteMessages(channelId: String, messageIds: [String], token: String) async throws {
        guard !messageIds.isEmpty else { return }
        if messageIds.count == 1 {
            try await deleteMessage(channelId: channelId, messageId: messageIds[0], token: token)
            return
        }
        let batch = Array(messageIds.prefix(100))
        let body = try JSONSerialization.data(withJSONObject: ["messages": batch])
        let req = try makeRequest(path: "/channels/\(channelId)/messages/bulk-delete", method: "POST", token: token, body: body)
        _ = try await executeRaw(req)
    }

    func toggleReaction(channelId: String, messageId: String, emojiIdentifier: String, add: Bool, token: String) async throws {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        let encoded = emojiIdentifier.addingPercentEncoding(withAllowedCharacters: allowed) ?? emojiIdentifier
        let req = try makeRequest(
            path: "/channels/\(channelId)/messages/\(messageId)/reactions/\(encoded)/@me",
            method: add ? "PUT" : "DELETE",
            token: token
        )
        _ = try await executeRaw(req)
    }

    func fetchPinnedMessages(channelId: String, token: String) async throws -> [DiscordMessage] {
        let req = try makeRequest(path: "/channels/\(channelId)/pins", token: token)
        return try await execute(req, as: [DiscordMessage].self)
    }

    func pinMessage(channelId: String, messageId: String, pin: Bool, token: String) async throws {
        let req = try makeRequest(path: "/channels/\(channelId)/pins/\(messageId)", method: pin ? "PUT" : "DELETE", token: token)
        _ = try await executeRaw(req)
    }

    func createDM(recipientId: String, token: String) async throws -> DiscordChannel {
        let body = try JSONSerialization.data(withJSONObject: ["recipient_id": recipientId])
        let req = try makeRequest(path: "/users/@me/channels", method: "POST", token: token, body: body)
        return try await execute(req, as: DiscordChannel.self)
    }

    func sendTyping(channelId: String, token: String) async {
        guard let req = try? makeRequest(path: "/channels/\(channelId)/typing", method: "POST", token: token) else { return }
        _ = try? await executeRaw(req)
    }
}
