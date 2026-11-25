import Foundation
import Network
import Combine
import CryptoKit

final class LocalBotProxyServer: ObservableObject {
    static let shared = LocalBotProxyServer()

    @Published private(set) var port: UInt16 = 0
    @Published private(set) var isReady: Bool = false

    private let queue = DispatchQueue(label: "com.maniakov.discordbotclient.proxy", qos: .userInitiated)
    private var listener: NWListener?
    private var desiredPort: UInt16 = 0
    private var cachedPatchedHTML: String?
    private let userAgent = "DiscordBot (https://github.com/aiko-chan-ai/DiscordBotClient, 3.10.7)"
    private let maxBodyBytes = 25 * 1024 * 1024

    private lazy var urlSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60
        return URLSession(configuration: cfg, delegate: NoRedirectSessionDelegate.shared, delegateQueue: nil)
    }()

    private lazy var assetCacheDir: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("dbc-assets-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private init() {}

    var baseURL: URL? {
        guard port > 0 else { return nil }
        return URL(string: "http://127.0.0.1:\(port)")
    }

    func start() {
        queue.async { [weak self] in
            self?.startListenerOnQueue()
        }
    }

    func ensureRunning() {
        queue.async { [weak self] in
            guard let self = self else { return }
            if let listener = self.listener, listener.state == .ready {
                return
            }
            self.listener?.cancel()
            self.listener = nil
            self.startListenerOnQueue()
        }
    }

    func clearCache() {
        queue.async { [weak self] in
            guard let self = self else { return }
            try? FileManager.default.removeItem(at: self.assetCacheDir)
            try? FileManager.default.createDirectory(at: self.assetCacheDir, withIntermediateDirectories: true)
            self.cachedPatchedHTML = nil
        }
    }

    private func startListenerOnQueue() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let nwPort: NWEndpoint.Port = (desiredPort > 0 ? NWEndpoint.Port(rawValue: desiredPort) : nil) ?? .any
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)

            let newListener = try NWListener(using: params)
            newListener.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    let bound = newListener.port?.rawValue ?? self.desiredPort
                    if bound > 0 {
                        self.desiredPort = bound
                    }
                    DispatchQueue.main.async {
                        self.port = bound
                        self.isReady = bound > 0
                    }
                case .failed:
                    DispatchQueue.main.async {
                        self.isReady = false
                    }
                    self.desiredPort = 0
                    newListener.cancel()
                    self.listener = nil
                case .cancelled:
                    DispatchQueue.main.async {
                        self.isReady = false
                    }
                default:
                    break
                }
            }
            newListener.newConnectionHandler = { [weak self] conn in
                self?.handleConnection(conn)
            }
            self.listener = newListener
            newListener.start(queue: queue)
        } catch {
            desiredPort = 0
        }
    }

    // MARK: - HTTP Connection Framing

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        readHTTPRequest(from: connection, buffer: Data())
    }

    private func readHTTPRequest(from connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if error != nil {
                connection.cancel()
                return
            }
            var acc = buffer
            if let data = data, !data.isEmpty {
                acc.append(data)
            }

            if let parsed = self.tryParseRequest(from: acc) {
                switch parsed {
                case .needMoreData:
                    if isComplete || acc.count > self.maxBodyBytes + 65536 {
                        self.sendResponse(status: 400, headers: ["Content-Type": "text/plain"], body: Data("Bad Request".utf8), on: connection)
                    } else {
                        self.readHTTPRequest(from: connection, buffer: acc)
                    }
                case .tooLarge:
                    self.sendResponse(status: 413, headers: ["Content-Type": "application/json"], body: Data("{\"error\":\"Payload too large\"}".utf8), on: connection)
                case .complete(let request):
                    Task {
                        let response = await self.routeRequest(request)
                        self.sendResponse(status: response.status, headers: response.headers, body: response.body, on: connection)
                    }
                }
            } else {
                if isComplete {
                    connection.cancel()
                } else {
                    self.readHTTPRequest(from: connection, buffer: acc)
                }
            }
        }
    }

    private enum ParseResult {
        case needMoreData
        case tooLarge
        case complete(ParsedHTTPRequest)
    }

    private struct ParsedHTTPRequest {
        let method: String
        let rawTarget: String
        let path: String
        let query: String
        let headers: [String: String]
        let body: Data
    }

    private struct HTTPResponse {
        let status: Int
        var headers: [String: String]
        let body: Data
    }

    private func tryParseRequest(from data: Data) -> ParseResult? {
        let sep = Data("\r\n\r\n".utf8)
        guard let headerEndRange = data.range(of: sep) else {
            return data.count > 65536 ? .tooLarge : .needMoreData
        }
        let headerData = data.subdata(in: 0..<headerEndRange.lowerBound)
        guard let headerStr = String(data: headerData, encoding: .utf8) else {
            return nil
        }
        let lines = headerStr.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return nil }

        let method = String(parts[0]).uppercased()
        let rawTarget = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[k] = v
            }
        }

        let bodyStart = headerEndRange.upperBound
        let availableBody = data.subdata(in: bodyStart..<data.count)

        if let te = headers["transfer-encoding"]?.lowercased(), te.contains("chunked") {
            if let decoded = decodeChunkedBody(availableBody) {
                if decoded.count > maxBodyBytes { return .tooLarge }
                return .complete(makeParsedRequest(method: method, rawTarget: rawTarget, headers: headers, body: decoded))
            }
            return .needMoreData
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        if contentLength > maxBodyBytes {
            return .tooLarge
        }
        if availableBody.count < contentLength {
            return .needMoreData
        }
        let body = contentLength > 0 ? availableBody.prefix(contentLength) : Data()
        return .complete(makeParsedRequest(method: method, rawTarget: rawTarget, headers: headers, body: Data(body)))
    }

    private func makeParsedRequest(method: String, rawTarget: String, headers: [String: String], body: Data) -> ParsedHTTPRequest {
        let qSplit = rawTarget.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(qSplit[0])
        let query = qSplit.count > 1 ? String(qSplit[1]) : ""
        return ParsedHTTPRequest(method: method, rawTarget: rawTarget, path: path, query: query, headers: headers, body: body)
    }

    private func decodeChunkedBody(_ data: Data) -> Data? {
        var idx = 0
        var out = Data()
        let crlf = Data("\r\n".utf8)
        while idx < data.count {
            guard let lineEnd = data[idx...].range(of: crlf) else { return nil }
            let sizeStr = String(data: data[idx..<lineEnd.lowerBound], encoding: .ascii)?
                .split(separator: ";").first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard let chunkSize = Int(sizeStr, radix: 16) else { return nil }
            idx = lineEnd.upperBound
            if chunkSize == 0 {
                return out
            }
            guard idx + chunkSize + 2 <= data.count else { return nil }
            out.append(data[idx..<(idx + chunkSize)])
            idx += chunkSize + 2
        }
        return nil
    }

    private func sendResponse(status: Int, headers: [String: String], body: Data, on connection: NWConnection) {
        var mergedHeaders = headers
        mergedHeaders["Content-Length"] = "\(body.count)"
        mergedHeaders["Connection"] = "close"
        if mergedHeaders["Access-Control-Allow-Origin"] == nil {
            mergedHeaders["Access-Control-Allow-Origin"] = "*"
        }

        var head = "HTTP/1.1 \(status) \(reasonPhrase(for: status))\r\n"
        for (k, v) in mergedHeaders {
            head += "\(k): \(v)\r\n"
        }
        head += "\r\n"

        var packet = Data(head.utf8)
        packet.append(body)

        connection.send(content: packet, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 302: return "Found"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        default: return "OK"
        }
    }

    // MARK: - Router

    private func routeRequest(_ req: ParsedHTTPRequest) async -> HTTPResponse {
        if req.method == "OPTIONS" {
            return HTTPResponse(
                status: 204,
                headers: [
                    "Access-Control-Allow-Origin": "*",
                    "Access-Control-Allow-Methods": "GET, POST, PUT, PATCH, DELETE, OPTIONS",
                    "Access-Control-Allow-Headers": "*"
                ],
                body: Data()
            )
        }

        let path = req.path

        if path.hasSuffix(".map") {
            return HTTPResponse(status: 404, headers: ["Content-Type": "text/plain"], body: Data())
        }

        // 1. Bridge & GCS upload
        if path == "/dbc-bridge/get-bot-info" && req.method == "POST" {
            return await handleGetBotInfo(req)
        }
        if path == "/dbc-gcs-upload" {
            return await handleGCSUpload(req)
        }

        // 2. Static bundle routes
        if path.hasPrefix("/vencord-ext/") {
            let rel = String(path.dropFirst("/vencord-ext/".count))
            return serveResourceFile(subpath: "vencord-ext/\(rel)", noCache: true)
        }
        if path.hasPrefix("/dbc-assets/") {
            let rel = String(path.dropFirst("/dbc-assets/".count))
            return serveResourceFile(subpath: "dbc-assets/\(rel)", noCache: true)
        }
        if path == "/dbc-editor" || path.hasPrefix("/dbc-editor/") {
            var rel = path == "/dbc-editor" ? "index.html" : String(path.dropFirst("/dbc-editor/".count))
            if rel.isEmpty || rel.hasSuffix("/") { rel += "index.html" }
            return serveResourceFile(subpath: "dbc-editor/\(rel)", noCache: false)
        }
        if path == "/manifest.json" {
            return serveResourceFile(subpath: "dbc-assets/pwa-manifest.json", noCache: true)
        }
        if path == "/sw.js" {
            let js = """
            self.addEventListener("install", () => self.skipWaiting());
            self.addEventListener("activate", (event) => {
              event.waitUntil(
                caches.keys().then((keys) => Promise.all(keys.map((k) => caches.delete(k))))
                  .then(() => self.registration.unregister())
              );
            });
            """
            return HTTPResponse(
                status: 200,
                headers: [
                    "Content-Type": "application/javascript; charset=utf-8",
                    "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0"
                ],
                body: Data(js.utf8)
            )
        }
        if path.hasPrefix("/assets/version.") && path.hasSuffix(".json") {
            return jsonResponse(["hash": "7f7c08c79473d1dfb12023bff0a35a6f9097c383", "required_action": NSNull()])
        }
        if path.hasPrefix("/assets/") {
            let name = String(path.dropFirst("/assets/".count))
            if let assetResp = await handleCachedAsset(name: name) {
                return assetResp
            }
        }
        if path.hasPrefix("/developers/") {
            return HTTPResponse(status: 302, headers: ["Location": "/app"], body: Data())
        }

        // 3. API Routes (Stubs -> Blacklist -> Proxy)
        if req.rawTarget.contains("/api/") || path.hasPrefix("/api/") {
            if let stub = await handleAPIStubs(req) {
                return stub
            }
            if isBlacklisted(req.rawTarget) {
                return jsonResponse(["message": "APIServer: Bots cannot use this endpoint", "code": 20001], status: 403)
            }
            return await proxyToDiscord(req)
        }

        // 4. Main Discord Web HTML routes
        if path == "/" || path == "/app" || path == "/login" || path == "/register"
            || path == "/channels" || path.hasPrefix("/channels/")
            || path == "/settings" || path.hasPrefix("/settings/") {
            let html = buildPatchedDiscordHTML()
            return HTTPResponse(
                status: 200,
                headers: [
                    "Content-Type": "text/html; charset=utf-8",
                    "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0"
                ],
                body: Data(html.utf8)
            )
        }

        // 5. Fallback proxy for any remaining Discord static assets
        return await proxyToDiscord(req)
    }

    // MARK: - Patched Discord HTML

    private func resourceURL(subpath: String) -> URL? {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("Resources", isDirectory: true) else {
            return nil
        }
        let cleaned = subpath.split(separator: "/").filter { $0 != ".." && $0 != "." }.joined(separator: "/")
        return root.appendingPathComponent(cleaned)
    }

    private func serveResourceFile(subpath: String, noCache: Bool) -> HTTPResponse {
        guard let fileURL = resourceURL(subpath: subpath),
              FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            return HTTPResponse(status: 404, headers: ["Content-Type": "text/plain"], body: Data("Not Found".utf8))
        }
        var headers: [String: String] = ["Content-Type": mimeType(for: fileURL.pathExtension)]
        if noCache {
            headers["Cache-Control"] = "no-store, no-cache, must-revalidate, max-age=0"
        } else {
            headers["Cache-Control"] = "public, max-age=3600"
        }
        return HTTPResponse(status: 200, headers: headers, body: data)
    }

    private func buildPatchedDiscordHTML() -> String {
        if let cached = cachedPatchedHTML {
            return cached
        }
        guard let htmlURL = resourceURL(subpath: "snapshot/index.html"),
              var html = try? String(contentsOf: htmlURL, encoding: .utf8) else {
            return "<html><body style='background:#111214;color:#fff;font-family:-apple-system;padding:32px;'>Missing snapshot/index.html</body></html>"
        }

        // 1. Strip Cloudflare challenge script
        html = html.replacingOccurrences(
            of: #"<script[^>]*>\s*\(function\(\)\s*\{\s*function c\(\)[\s\S]*?</script>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        // 2. Strip nonce & viewport
        html = html.replacingOccurrences(of: #"\snonce="[^"]*""#, with: "", options: .regularExpression)
        html = html.replacingOccurrences(of: #"<meta[^>]*viewport[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
        // 2c. Strip redundant script preloads
        html = html.replacingOccurrences(
            of: #"<link\s+as="script"\s+href="/assets/(?!(web\.f86c748842ee176f|585600\.85ec39628d89fab2|41814\.16b66adbca89c196)\.js)[^"]+"\s+rel="preload">\s*"#,
            with: "",
            options: .regularExpression
        )

        // 3. Point GLOBAL_ENV endpoints to loopback origin
        html = html.replacingOccurrences(of: "\"API_ENDPOINT\": \"//discord.com/api\"", with: "\"API_ENDPOINT\": \"//\" + window.location.host + \"/api\"")
        html = html.replacingOccurrences(of: "\"WEBAPP_ENDPOINT\": \"//discord.com\"", with: "\"WEBAPP_ENDPOINT\": \"//\" + window.location.host")
        html = html.replacingOccurrences(of: "\"ASSET_ENDPOINT\": \"//discord.com\"", with: "\"ASSET_ENDPOINT\": \"//\" + window.location.host")
        html = html.replacingOccurrences(of: "\"API_PROTOCOL\": \"https:\"", with: "\"API_PROTOCOL\": \"http:\"")
        html = html.replacingOccurrences(of: "\"PRIMARY_DOMAIN\": \"discord.com\"", with: "\"PRIMARY_DOMAIN\": window.location.host")
        html = html.replacingOccurrences(of: "\"MIGRATION_DESTINATION_ORIGIN\": \"https://discord.com\"", with: "\"MIGRATION_DESTINATION_ORIGIN\": window.location.origin")

        // 4. Disable inline fast-connect WebSocket
        html = html.replacingOccurrences(of: "if (null != window.WebSocket &&", with: "if (false && null != window.WebSocket &&")

        let mobileCSS = (try? resourceURL(subpath: "dbc-assets/dbc-mobile.css").flatMap { try String(contentsOf: $0, encoding: .utf8) }) ?? ""
        let guildExp = loadJSONFragment(subpath: "snapshot/guild_experiments.json", fallback: "[]")
        let userExp = loadJSONFragment(subpath: "snapshot/user_experiments.json", fallback: "[]")
        let apexExp = loadJSONFragment(subpath: "snapshot/apex_experiments.json", fallback: "{}")

        let defaultUserPatchJSON = """
        {"id":"1056491867375673424","username":"aiko-chan-ai","global_name":"Elysia","avatar":"93fb88f6b8c0a2a33c437d0fff4c6625","avatar_decoration":null,"discriminator":"0000","public_flags":1,"flags":1,"bot":true,"system":true,"banner":null,"accent_color":null}
        """
        let bootScript = """
        window.__DBC_BOOT__ = {"version":"3.10.7","name":"DiscordBotClient","defaultUserPatch":\(defaultUserPatchJSON),"guildExperiments":\(guildExp),"userExperiments":\(userExp),"apexExperiments":\(apexExp)};
        """

        let ts = Int(Date().timeIntervalSince1970)
        let injection = """
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover">
            <meta name="apple-mobile-web-app-capable" content="yes">
            <meta name="mobile-web-app-capable" content="yes">
            <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
            <meta name="apple-mobile-web-app-title" content="BotClient">
            <link rel="manifest" href="/manifest.json">
            <link rel="apple-touch-icon" href="/dbc-assets/icon.png">
            <link rel="icon" type="image/png" href="/dbc-assets/icon.png">
            <style id="dbc-mobile-inline">\(mobileCSS)</style>
            <link rel="stylesheet" href="/vencord-ext/dist/Vencord.css?v=\(ts)">
            <link rel="stylesheet" href="/dbc-assets/dbc-mobile.css?v=\(ts)">
            <script>\(bootScript)</script>
            <script src="/dbc-assets/dbc-web-bridge.js?v=\(ts)"></script>
            <script src="/vencord-ext/dist/Vencord.js?v=\(ts)"></script>
        """

        if let range = html.range(of: "<head>") {
            html.replaceSubrange(range, with: injection)
        }
        cachedPatchedHTML = html
        return html
    }

    private func loadJSONFragment(subpath: String, fallback: String) -> String {
        guard let url = resourceURL(subpath: subpath),
              let txt = try? String(contentsOf: url, encoding: .utf8),
              !txt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fallback
        }
        return txt
    }

    // MARK: - Bridge & GCS Proxy

    private func handleGetBotInfo(_ req: ParsedHTTPRequest) async -> HTTPResponse {
        let jsonObj = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any]
        guard let rawToken = jsonObj?["token"] as? String, rawToken.count <= 512 else {
            return jsonResponse(["success": false, "message": "Invalid bot token."])
        }
        let token = KeychainBotStore.normalizeToken(rawToken)
        guard !token.isEmpty else {
            return jsonResponse(["success": false, "message": "Invalid bot token."])
        }

        guard let url = URL(string: "https://canary.discord.com/api/v9/applications/@me?with_counts=true") else {
            return jsonResponse(["success": false, "message": "Invalid Discord URL"])
        }
        var urlReq = URLRequest(url: url)
        urlReq.timeoutInterval = 10
        urlReq.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        urlReq.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await urlSession.data(for: urlReq)
            guard let http = response as? HTTPURLResponse else {
                return jsonResponse(["success": false, "message": "No HTTP response"])
            }
            guard (200..<300).contains(http.statusCode),
                  let appObj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                let errObj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let errMsg = (errObj?["message"] as? String) ?? "HTTP \(http.statusCode)"
                return jsonResponse(["success": false, "message": "Discord API Error [\(http.statusCode)]: \(errMsg)"])
            }

            let flags = (appObj["flags"] as? Int) ?? 0
            // GatewayIntentBits allIntents bitmask = 53608447
            var intents = 53_608_447
            let hasPresence = (flags & ((1 << 12) | (1 << 13))) != 0
            let hasMembers = (flags & ((1 << 14) | (1 << 15))) != 0
            let hasMessageContent = (flags & ((1 << 18) | (1 << 19))) != 0
            if !hasPresence { intents &= ~(1 << 8) }
            if !hasMembers { intents &= ~(1 << 1) }
            if !hasMessageContent { intents &= ~(1 << 15) }

            let approxGuilds = (appObj["bot_approximate_guild_count"] as? Int)
                ?? (appObj["approximate_guild_count"] as? Int)
                ?? 0
            let allShards = max(1, Int(ceil(Double(approxGuilds) / 2500.0)))

            // Auto-save authenticated bot into iOS Keychain Vault
            let botDict = appObj["bot"] as? [String: Any]
            let botId = (botDict?["id"] as? String) ?? (appObj["id"] as? String)
            let botName = (appObj["name"] as? String) ?? (botDict?["username"] as? String)
            let botUsername = botDict?["username"] as? String
            let avatarHash = (botDict?["avatar"] as? String) ?? (appObj["icon"] as? String)
            let avatarURL: String? = {
                guard let bid = botId, let hash = avatarHash, !hash.isEmpty else { return nil }
                return "https://cdn.discordapp.com/avatars/\(bid)/\(hash).png"
            }()

            await MainActor.run {
                KeychainBotStore.shared.saveOrUpdateBot(
                    token: token,
                    name: botName,
                    username: botUsername,
                    id: botId,
                    avatarURL: avatarURL
                )
            }

            return jsonResponse([
                "success": true,
                "data": appObj,
                "intents": intents,
                "allShards": allShards
            ])
        } catch {
            return jsonResponse(["success": false, "message": error.localizedDescription])
        }
    }

    private func handleGCSUpload(_ req: ParsedHTTPRequest) async -> HTTPResponse {
        guard let comps = URLComponents(string: "http://localhost\(req.rawTarget)"),
              let targetUrlStr = comps.queryItems?.first(where: { $0.name == "url" })?.value,
              targetUrlStr.range(
                of: #"^https://discord-attachments-uploads-[a-z0-9-]+\.storage\.googleapis\.com/"#,
                options: [.regularExpression, .caseInsensitive]
              ) != nil,
              let targetURL = URL(string: targetUrlStr) else {
            return jsonResponse(["error": "Invalid GCS upload target URL"], status: 400)
        }

        var urlReq = URLRequest(url: targetURL)
        urlReq.httpMethod = "PUT"
        urlReq.timeoutInterval = 45
        urlReq.setValue(req.headers["content-type"] ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
        urlReq.httpBody = req.body

        do {
            let (respData, response) = try await urlSession.data(for: urlReq)
            guard let http = response as? HTTPURLResponse else {
                return jsonResponse(["error": "GCS upload proxy failed"], status: 502)
            }
            var outHeaders: [String: String] = ["Content-Type": "application/octet-stream"]
            if let etag = http.value(forHTTPHeaderField: "ETag") {
                outHeaders["ETag"] = etag
                outHeaders["Access-Control-Expose-Headers"] = "ETag"
            }
            return HTTPResponse(status: http.statusCode, headers: outHeaders, body: respData)
        } catch {
            return jsonResponse(["error": error.localizedDescription], status: 502)
        }
    }

    // MARK: - Disk-Cached Discord Assets

    private func handleCachedAsset(name: String) async -> HTTPResponse? {
        guard name.range(of: #"^[\w.-]+$"#, options: .regularExpression) != nil,
              !name.hasSuffix(".map") else {
            return HTTPResponse(status: 404, headers: ["Content-Type": "text/plain"], body: Data())
        }

        let fileURL = assetCacheDir.appendingPathComponent(name)
        let typeURL = assetCacheDir.appendingPathComponent("\(name).type")
        if let cachedData = try? Data(contentsOf: fileURL),
           let cachedType = try? String(contentsOf: typeURL, encoding: .utf8) {
            return HTTPResponse(
                status: 200,
                headers: [
                    "Content-Type": cachedType,
                    "Cache-Control": "public, max-age=31536000, immutable"
                ],
                body: cachedData
            )
        }

        guard let upstreamURL = URL(string: "https://canary.discord.com/assets/\(name)") else { return nil }
        var req = URLRequest(url: upstreamURL)
        req.timeoutInterval = 20
        do {
            let (data, response) = try await urlSession.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            let mime = http.value(forHTTPHeaderField: "Content-Type") ?? mimeType(for: (name as NSString).pathExtension)
            try? data.write(to: fileURL)
            try? mime.write(to: typeURL, atomically: true, encoding: .utf8)
            return HTTPResponse(
                status: 200,
                headers: [
                    "Content-Type": mime,
                    "Cache-Control": "public, max-age=31536000, immutable"
                ],
                body: data
            )
        } catch {
            return nil
        }
    }

    // MARK: - API Stub Routes & Proxy

    private func stripAPIPrefix(_ path: String) -> String {
        for prefix in ["/api/v10", "/api/v9", "/api"] {
            if path.hasPrefix(prefix) {
                let rest = String(path.dropFirst(prefix.count))
                return rest.isEmpty ? "/" : rest
            }
        }
        return path
    }

    private func handleAPIStubs(_ req: ParsedHTTPRequest) async -> HTTPResponse? {
        let sub = stripAPIPrefix(req.path)

        switch sub {
        case "/experiments":
            return jsonResponse(["fingerprint": "", "assignments": [], "guild_experiments": []])

        case "/users/@me/settings-proto/1", "/users/@me/settings-proto/2":
            return jsonResponse(["settings": ""])

        case "/users/@me":
            if req.method == "GET" {
                return await handleUsersMe(req)
            }

        case "/users/@me/emojis":
            return await handleUserEmojis(req)

        case "/users/@me/mentions":
            return jsonResponse([])

        case "/users/@me/relationships":
            return jsonResponse([])

        case "/users/@me/affinities/guilds":
            return jsonResponse(["guild_affinities": []])

        case "/users/@me/affinities/users":
            return jsonResponse(["user_affinities": [], "inverse_user_affinities": []])

        case "/users/@me/application-command-index":
            return jsonResponse(["applications": [], "application_commands": [], "version": "1000000000000000000"])

        case "/users/@me/custom-themes":
            return HTTPResponse(status: 204, headers: ["Content-Type": "application/json"], body: Data())

        case "/users/@me/connections",
             "/users/@me/mfa/webauthn/credentials",
             "/users/@me/outbound-promotions/codes",
             "/users/@me/entitlements",
             "/users/@me/entitlements/gifts",
             "/users/@me/guilds/premium/subscriptions",
             "/users/@me/guilds/premium/subscription-slots",
             "/users/@me/billing/payment-sources",
             "/users/@me/billing/payments",
             "/users/@me/billing/subscriptions",
             "/users/@me/library",
             "/users/@me/inventory",
             "/users/@me/saved-messages",
             "/users/@me/unclaimed-games",
             "/users/@me/video-filters/assets",
             "/users/@me/avatars",
             "/users/@me/program-rewards",
             "/guilds/premium/subscription-slots",
             "/app-recommendations":
            return jsonResponse([])

        case "/users/@me/billing/country-code", "/users/@me/billing/location-info":
            return jsonResponse(["country_code": "VN"])

        case "/users/@me/billing/campaign-context", "/users/@me/billing/nitro-affinity", "/__development/build_overrides":
            return jsonResponse([:])

        case "/users/@me/notification-center/items":
            return jsonResponse(["limit": 20, "items": [], "cursor": "1000000000000000000", "has_more": false])

        case "/users/@me/virtual-currency/balance":
            return jsonResponse(["balance": 0])

        case "/users/@me/meaningfully-online":
            return jsonResponse(["meaningfully_online": true])

        case "/users/@me/widgets/application-widget-application-ids":
            return jsonResponse(["application_configs": []])

        case "/users/@me/widgets/suggested-games":
            return jsonResponse(["suggested_games": [], "suggested_wishlist_games": []])

        case "/quests/@me", "/quests/@me/claimed":
            return jsonResponse(["quests": [], "excluded_quests": [], "quest_enrollment_blocked_until": NSNull()])

        case "/quests/decision":
            return jsonResponse(["quest": NSNull()])

        case "/quests/get-decisions":
            return jsonResponse(["request_id": UUID().uuidString, "decisions": []])

        case "/auth/location-metadata":
            return jsonResponse([
                "consent_required": false,
                "country_code": "VN",
                "promotional_email_opt_in": ["required": true, "pre_checked": false]
            ])

        case "/auth/logout":
            return HTTPResponse(status: 204, headers: ["Content-Type": "application/json"], body: Data())

        case "/auth/sessions":
            return jsonResponse([
                "user_sessions": [
                    [
                        "id_hash": Data("aiko-chan-ai/DiscordBotClient".utf8).base64EncodedString(),
                        "approx_last_used_time": ISO8601DateFormatter().string(from: Date()),
                        "client_info": [
                            "os": "iOS",
                            "platform": "DiscordBotClient",
                            "location": "Aedes Elysiae"
                        ]
                    ]
                ]
            ])

        case "/read-states/ack-bulk":
            return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: Data())

        case "/ping":
            return jsonResponse(["code": 0, "message": "OK", "version": "1.0.0", "isBotClient": true])

        case "/popout":
            return await proxyArbitraryURL("https://canary.discord.com/popout", contentTypeFallback: "text/html; charset=utf-8")

        default:
            break
        }

        // Prefix/pattern stub routes
        if sub.hasPrefix("/quests/") {
            return jsonResponse(["quests": [], "excluded_quests": []])
        }
        if sub.hasPrefix("/users/@me/billing/") || sub.hasPrefix("/billing/") {
            return jsonResponse([])
        }
        if sub.hasPrefix("/auth/") {
            return jsonResponse([:])
        }
        if sub.hasPrefix("/users/@me/mentions") {
            return jsonResponse([])
        }

        let segs = sub.split(separator: "/").map(String.init)
        // /users/:id/profile
        if segs.count == 3 && segs[0] == "users" && segs[2] == "profile" {
            if req.method == "PATCH" {
                var patched = req
                patched = ParsedHTTPRequest(method: "PATCH", rawTarget: "/api/v9/users/@me", path: "/api/v9/users/@me", query: "", headers: req.headers, body: req.body)
                return await proxyToDiscord(patched)
            }
            return await handleUserProfile(userId: segs[1], req: req)
        }
        // /guilds/:id/profile
        if segs.count >= 3 && segs[0] == "guilds" && segs[2] == "profile" {
            return await handleGuildProfile(guildId: segs[1], req: req)
        }
        // /channels/:id/messages/search
        if segs.count == 4 && segs[0] == "channels" && segs[2] == "messages" && segs[3] == "search" {
            return await handleChannelMessagesSearch(channelId: segs[1], req: req)
        }
        // /channels/:id/threads/search
        if segs.count == 4 && segs[0] == "channels" && segs[2] == "threads" && segs[3] == "search" {
            return await handleChannelThreadsSearch(channelId: segs[1], req: req)
        }
        // /channels/:id/messages/:mid/ack or /channels/:id/explicit-media
        if segs.count >= 3 && segs[0] == "channels" && (segs.last == "ack" || segs.last == "explicit-media") {
            return jsonResponse(["token": NSNull()])
        }

        return nil
    }

    private func handleUsersMe(_ req: ParsedHTTPRequest) async -> HTTPResponse {
        guard let auth = normalizedAuthHeader(from: req.headers),
              let url = URL(string: "https://canary.discord.com/api/v9/users/@me") else {
            return jsonResponse(["message": "Missing bot token"], status: 401)
        }
        var urlReq = URLRequest(url: url)
        urlReq.setValue(auth, forHTTPHeaderField: "Authorization")
        urlReq.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await urlSession.data(for: urlReq)
            guard let http = response as? HTTPURLResponse else {
                return jsonResponse(["message": "Upstream error"], status: 502)
            }
            guard (200..<300).contains(http.statusCode),
                  var user = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return HTTPResponse(status: http.statusCode, headers: ["Content-Type": "application/json"], body: data)
            }
            let uid = (user["id"] as? String) ?? "0"
            user["premium"] = true
            user["premium_type"] = 1
            user["mfa_enabled"] = 1
            user["flags"] = 476111
            user["public_flags"] = 476111
            user["phone"] = "33550336"
            user["verified"] = true
            user["nsfw_allowed"] = true
            user["email"] = "\(uid)@cyrene.moe"
            user["purchased_flags"] = 3
            return jsonResponse(user)
        } catch {
            return jsonResponse(["message": "Internal Server Error"], status: 500)
        }
    }

    private func handleUserEmojis(_ req: ParsedHTTPRequest) async -> HTTPResponse {
        guard let auth = normalizedAuthHeader(from: req.headers),
              let botId = extractUserId(fromAuth: auth),
              let url = URL(string: "https://canary.discord.com/api/v9/applications/\(botId)/emojis") else {
            return jsonResponse([])
        }
        var urlReq = URLRequest(url: url)
        urlReq.setValue(auth, forHTTPHeaderField: "Authorization")
        urlReq.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let (data, _) = try? await urlSession.data(for: urlReq),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let items = obj["items"] as? [[String: Any]] {
            return jsonResponse(items)
        }
        return jsonResponse([])
    }

    private func handleUserProfile(userId: String, req: ParsedHTTPRequest) async -> HTTPResponse {
        guard let auth = normalizedAuthHeader(from: req.headers) else {
            return jsonResponse(["message": "Unauthorized"], status: 401)
        }
        let comps = URLComponents(string: "http://localhost\(req.rawTarget)")
        let guildId = comps?.queryItems?.first(where: { $0.name == "guild_id" })?.value
        let botId = extractUserId(fromAuth: auth)
        let isSelf = (botId == userId)

        var guildMember: [String: Any]? = nil
        if let gid = guildId, !gid.isEmpty {
            let memberPath = isSelf ? "guilds/\(gid)/members/@me" : "guilds/\(gid)/members/\(userId)"
            if let mURL = URL(string: "https://canary.discord.com/api/v9/\(memberPath)") {
                var mReq = URLRequest(url: mURL)
                mReq.setValue(auth, forHTTPHeaderField: "Authorization")
                mReq.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                if let (mData, mRes) = try? await urlSession.data(for: mReq),
                   let http = mRes as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    guildMember = (try? JSONSerialization.jsonObject(with: mData)) as? [String: Any]
                }
            }
        }

        var bio: String? = nil
        if isSelf, let appURL = URL(string: "https://canary.discord.com/api/v9/applications/@me") {
            var aReq = URLRequest(url: appURL)
            aReq.setValue(auth, forHTTPHeaderField: "Authorization")
            aReq.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            if let (aData, _) = try? await urlSession.data(for: aReq),
               let appObj = (try? JSONSerialization.jsonObject(with: aData)) as? [String: Any] {
                bio = appObj["description"] as? String
            }
        }

        guard let uURL = URL(string: "https://canary.discord.com/api/v9/users/\(userId)") else {
            return jsonResponse(["message": "Bad user id"], status: 400)
        }
        var uReq = URLRequest(url: uURL)
        uReq.setValue(auth, forHTTPHeaderField: "Authorization")
        uReq.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (uData, uRes) = try await urlSession.data(for: uReq)
            guard let http = uRes as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let userObj = (try? JSONSerialization.jsonObject(with: uData)) as? [String: Any] else {
                return HTTPResponse(status: 500, headers: ["Content-Type": "application/json"], body: uData)
            }
            let isBot = (userObj["bot"] as? Bool) ?? false
            let memberBio = (guildMember?["bio"] as? String) ?? bio
            let memberBanner = guildMember?["banner"] ?? NSNull()

            var payload: [String: Any] = [
                "application_role_connections": [],
                "badges": [],
                "connected_accounts": [],
                "guild_badges": [],
                "guild_member": (guildMember as Any?) ?? NSNull(),
                "legacy_username": NSNull(),
                "mutual_friends": [],
                "mutual_friends_count": 0,
                "mutual_guilds": [],
                "premium_since": NSNull(),
                "premium_guild_since": NSNull(),
                "premium_type": isBot ? 2 : (userObj["premium_type"] ?? 0),
                "profile_themes_experiment_bucket": 4,
                "user": userObj,
                "user_profile": [
                    "accent_color": userObj["accent_color"] ?? NSNull(),
                    "banner": userObj["banner"] ?? NSNull(),
                    "bio": (bio as Any?) ?? NSNull(),
                    "collectibles": [],
                    "emoji": NSNull(),
                    "popout_animation_particle_type": NSNull(),
                    "profile_effect": NSNull(),
                    "pronouns": NSNull(),
                    "theme_colors": NSNull()
                ],
                "widgets": [],
                "wishlist_settings": [:]
            ]
            if guildMember != nil, let gid = guildId {
                payload["guild_member_profile"] = [
                    "guild_id": gid,
                    "pronouns": "",
                    "bio": (memberBio as Any?) ?? NSNull(),
                    "banner": memberBanner,
                    "accent_color": NSNull(),
                    "theme_colors": NSNull(),
                    "popout_animation_particle_type": NSNull(),
                    "emoji": NSNull(),
                    "profile_effect": NSNull()
                ]
            } else {
                payload["guild_member_profile"] = NSNull()
            }
            return jsonResponse(payload)
        } catch {
            return jsonResponse(["message": "Internal Server Error"], status: 500)
        }
    }

    private func handleGuildProfile(guildId: String, req: ParsedHTTPRequest) async -> HTTPResponse {
        guard let auth = normalizedAuthHeader(from: req.headers),
              let url = URL(string: "https://canary.discord.com/api/v9/guilds/\(guildId)?with_counts=true") else {
            return jsonResponse(["message": "Unauthorized"], status: 401)
        }
        var urlReq = URLRequest(url: url)
        urlReq.setValue(auth, forHTTPHeaderField: "Authorization")
        urlReq.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await urlSession.data(for: urlReq)
            guard let g = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let gid = g["id"] as? String else {
                return HTTPResponse(status: 403, headers: ["Content-Type": "application/json"], body: data)
            }
            let profile: [String: Any] = [
                "id": gid,
                "name": g["name"] ?? "",
                "icon_hash": g["icon"] ?? NSNull(),
                "member_count": g["approximate_member_count"] ?? 0,
                "online_count": g["approximate_presence_count"] ?? 0,
                "description": g["description"] ?? NSNull(),
                "banner_hash": g["banner"] ?? NSNull(),
                "game_application_ids": [],
                "game_activity": [:],
                "tag": NSNull(),
                "badge": 0,
                "badge_color_primary": "#ff0000",
                "badge_color_secondary": "#800000",
                "badge_hash": NSNull(),
                "traits": [],
                "features": g["features"] ?? [],
                "visibility": 2,
                "custom_banner_hash": NSNull(),
                "premium_subscription_count": g["premium_subscription_count"] ?? 0,
                "premium_tier": g["premium_tier"] ?? 0
            ]
            return jsonResponse(profile)
        } catch {
            return jsonResponse(["message": "Internal Server Error"], status: 500)
        }
    }

    private func handleChannelMessagesSearch(channelId: String, req: ParsedHTTPRequest) async -> HTTPResponse {
        guard let auth = normalizedAuthHeader(from: req.headers) else {
            return jsonResponse(["message": "Unauthorized"], status: 401)
        }
        let comps = URLComponents(string: "http://localhost\(req.rawTarget)")
        let targetChan = comps?.queryItems?.first(where: { $0.name == "channel_id" })?.value ?? channelId
        let maxId = comps?.queryItems?.first(where: { $0.name == "max_id" })?.value
        let minId = comps?.queryItems?.first(where: { $0.name == "min_id" })?.value

        var q = "limit=25"
        if let maxId = maxId, !maxId.isEmpty { q += "&before=\(maxId)" }
        if let minId = minId, !minId.isEmpty { q += "&after=\(minId)" }

        var wrapped: [[[String: Any]]] = []
        if let url = URL(string: "https://canary.discord.com/api/v9/channels/\(targetChan)/messages?\(q)") {
            var urlReq = URLRequest(url: url)
            urlReq.setValue(auth, forHTTPHeaderField: "Authorization")
            urlReq.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            if let (data, _) = try? await urlSession.data(for: urlReq),
               let msgs = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
                wrapped = msgs.map { m in
                    var hit = m
                    hit["hit"] = true
                    return [hit]
                }
            }
        }

        let digest = Insecure.MD5.hash(data: Data("\(Date().timeIntervalSince1970)elysia".utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        return jsonResponse([
            "analytics_id": hash,
            "doing_deep_historical_index": false,
            "total_results": wrapped.count,
            "messages": wrapped
        ])
    }

    private func handleChannelThreadsSearch(channelId: String, req: ParsedHTTPRequest) async -> HTTPResponse {
        let comps = URLComponents(string: "http://localhost\(req.rawTarget)")
        let archived = comps?.queryItems?.first(where: { $0.name == "archived" })?.value
        let tag = comps?.queryItems?.first(where: { $0.name == "tag" })?.value
        let name = comps?.queryItems?.first(where: { $0.name == "name" })?.value
        let limit = min(max(Int(comps?.queryItems?.first(where: { $0.name == "limit" })?.value ?? "25") ?? 25, 1), 100)

        if (tag != nil && !tag!.isEmpty) || (name != nil && !name!.isEmpty) || archived != "true" {
            return jsonResponse([
                "threads": [],
                "members": [],
                "has_more": false,
                "total_results": 0,
                "first_messages": [],
                "owners": []
            ])
        }

        guard let auth = normalizedAuthHeader(from: req.headers),
              let url = URL(string: "https://canary.discord.com/api/v9/channels/\(channelId)/threads/archived/public?limit=\(limit)") else {
            return jsonResponse(["threads": [], "members": [], "has_more": false, "total_results": 0, "first_messages": []])
        }
        var urlReq = URLRequest(url: url)
        urlReq.setValue(auth, forHTTPHeaderField: "Authorization")
        urlReq.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let (data, response) = try? await urlSession.data(for: urlReq),
           let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let threads = (obj["threads"] as? [[String: Any]]) ?? []
            let members = (obj["members"] as? [[String: Any]]) ?? []
            let hasMore = (obj["has_more"] as? Bool) ?? false
            return jsonResponse([
                "threads": threads,
                "members": members,
                "has_more": hasMore,
                "total_results": threads.count,
                "first_messages": [],
                "owners": []
            ])
        }
        return jsonResponse(["threads": [], "members": [], "has_more": false, "total_results": 0, "first_messages": []])
    }

    private func isBlacklisted(_ rawTarget: String) -> Bool {
        let blacklist = [
            "outbound-promotions/codes", "science", "applications/public", "notes",
            "member-ids", "connections/", "users/@me/disable", "users/@me/delete",
            "users/@me/mfa", "users/@me/phone", "interaction-data", "member-verification",
            "cdn-cgi/challenge-platform", "explicit-media", "premium/subscriptions",
            "/ack", "/stripe", "/paypal", "/validate-billing-address",
            "/custom-call-sounds", "auth/conditional/start"
        ]
        return blacklist.contains(where: { rawTarget.contains($0) })
    }

    private func proxyToDiscord(_ req: ParsedHTTPRequest) async -> HTTPResponse {
        guard let url = URL(string: "https://canary.discord.com\(req.rawTarget)") else {
            return jsonResponse(["error": "Invalid upstream URL"], status: 400)
        }
        var urlReq = URLRequest(url: url)
        urlReq.httpMethod = req.method
        urlReq.timeoutInterval = 25

        let skipReqHeaders: Set<String> = ["host", "connection", "content-length", "transfer-encoding", "upgrade", "origin", "cookie", "referer", "accept-encoding", "authorization"]
        for (k, v) in req.headers {
            let low = k.lowercased()
            if !skipReqHeaders.contains(low) && !low.hasPrefix("sec-") {
                urlReq.setValue(v, forHTTPHeaderField: k)
            }
        }
        if let auth = normalizedAuthHeader(from: req.headers) {
            urlReq.setValue(auth, forHTTPHeaderField: "Authorization")
            urlReq.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        urlReq.setValue("https://discord.com", forHTTPHeaderField: "Origin")
        urlReq.setValue("https://discord.com/", forHTTPHeaderField: "Referer")

        if ["POST", "PUT", "PATCH", "DELETE"].contains(req.method) && !req.body.isEmpty {
            urlReq.httpBody = req.body
        }

        do {
            let (data, response) = try await urlSession.data(for: urlReq)
            guard let http = response as? HTTPURLResponse else {
                return jsonResponse(["error": "Upstream returned no HTTP response"], status: 502)
            }
            let skipResHeaders: Set<String> = ["content-encoding", "content-length", "transfer-encoding", "connection"]
            var outHeaders: [String: String] = [:]
            for (k, v) in http.allHeaderFields {
                if let ks = k as? String, let vs = v as? String, !skipResHeaders.contains(ks.lowercased()) {
                    outHeaders[ks] = vs
                }
            }
            if outHeaders["Content-Type"] == nil && outHeaders["content-type"] == nil {
                outHeaders["Content-Type"] = "application/json; charset=utf-8"
            }
            return HTTPResponse(status: http.statusCode, headers: outHeaders, body: data)
        } catch {
            return jsonResponse(["error": error.localizedDescription], status: 502)
        }
    }

    private func proxyArbitraryURL(_ urlStr: String, contentTypeFallback: String) async -> HTTPResponse {
        guard let url = URL(string: urlStr) else {
            return HTTPResponse(status: 502, headers: ["Content-Type": "text/plain"], body: Data("Bad URL".utf8))
        }
        do {
            let (data, response) = try await urlSession.data(for: URLRequest(url: url))
            let http = response as? HTTPURLResponse
            let ct = http?.value(forHTTPHeaderField: "Content-Type") ?? contentTypeFallback
            return HTTPResponse(status: http?.statusCode ?? 200, headers: ["Content-Type": ct], body: data)
        } catch {
            return HTTPResponse(status: 502, headers: ["Content-Type": "text/plain"], body: Data("Proxy failed".utf8))
        }
    }

    // MARK: - Helpers

    private func normalizedAuthHeader(from headers: [String: String]) -> String? {
        guard let raw = headers["authorization"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if raw.lowercased().hasPrefix("bot ") {
            return "Bot " + raw.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "Bot " + raw
    }

    private func extractUserId(fromAuth auth: String) -> String? {
        let token = KeychainBotStore.normalizeToken(auth)
        guard let first = token.split(separator: ".").first else { return nil }
        var b64 = String(first).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let id = String(data: data, encoding: .utf8),
              !id.isEmpty,
              id.allSatisfy(\.isNumber) else {
            return nil
        }
        return id
    }

    private func jsonResponse(_ obj: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json; charset=utf-8"], body: data)
    }

    private func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "application/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "mp4": return "video/mp4"
        default: return "application/octet-stream"
        }
    }
}

private final class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate {
    static let shared = NoRedirectSessionDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
