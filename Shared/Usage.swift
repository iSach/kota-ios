import Foundation
import Security

enum Kota {
    private static let defaultAppGroup = "group.com.isach.kota"

    /// The App Group shared by app and widget. Must match both Config/*.entitlements files.
    /// AltStore/SideStore re-sign under a renamed group and record it in Info.plist as `ALTAppGroups`,
    /// so prefer that when present (the widget also checks its host app's Info.plist).
    static let appGroup: String = {
        let hostPlist = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Info.plist")
        let recorded = (Bundle.main.infoDictionary?["ALTAppGroups"] as? [String] ?? [])
            + (NSDictionary(contentsOf: hostPlist)?["ALTAppGroups"] as? [String] ?? [])
        return recorded.first { $0.hasPrefix(Self.defaultAppGroup) } ?? recorded.first ?? Self.defaultAppGroup
    }()

    static let defaults = UserDefaults(suiteName: appGroup)
    /// @AppStorage key: show "% used" instead of "% left".
    static let showsUsedKey = "showsUsed"
}

enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case claude, codex, opencodeGo

    var id: String { self.rawValue }
    var label: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .opencodeGo: "OpenCode Go"
        }
    }
}

/// One signed-in account. Name and order live in the shared defaults; credentials live in the Keychain.
struct Account: Codable, Identifiable, Hashable {
    enum Field: String, CaseIterable { case token, refresh }

    var id = UUID()
    var kind: ProviderKind
    var name: String

    static var all: [Account] {
        get {
            guard let data = Kota.defaults?.data(forKey: "accounts") else { return [] }
            return (try? JSONDecoder().decode([Account].self, from: data)) ?? []
        }
        set { Kota.defaults?.set(try? JSONEncoder().encode(newValue), forKey: "accounts") }
    }

    private func query(_ field: Field) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Kota.appGroup,
            kSecAttrAccount: "\(self.id.uuidString).\(field.rawValue)",
            kSecAttrAccessGroup: Kota.appGroup,
        ]
    }

    func secret(_ field: Field = .token) -> String? {
        var query = self.query(field)
        query[kSecReturnData] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Stores (or, for an empty value, deletes) a credential. Returns false when the Keychain rejected the
    /// write, which usually means a signing / App Group mismatch.
    @discardableResult
    func setSecret(_ raw: String, _ field: Field = .token) -> Bool {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("sessionKey=") { value.removeFirst("sessionKey=".count) }
        if value.lowercased().hasPrefix("bearer ") { value.removeFirst("bearer ".count) }
        SecItemDelete(self.query(field) as CFDictionary)
        guard !value.isEmpty else { return true }
        var query = self.query(field)
        query[kSecValueData] = Data(value.utf8)
        // AfterFirstUnlock so the widget can refresh while the phone is locked.
        query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    func deleteSecrets() {
        for field in Field.allCases { SecItemDelete(self.query(field) as CFDictionary) }
    }
}

struct UsageWindow: Codable, Hashable {
    let title: String
    let usedPercent: Double
    let resetsAt: Date?

    var percentUsed: Double { min(100, max(0, self.usedPercent)) }
    var percentLeft: Double { 100 - self.percentUsed }
}

struct ProviderUsage: Codable, Hashable, Identifiable {
    var id = UUID()
    let name: String
    var windows: [UsageWindow] = []
    var error: String?
}

struct Snapshot: Codable {
    var providers: [ProviderUsage] = []
    var date = Date()

    static var cached: Snapshot {
        guard let data = Kota.defaults?.data(forKey: "snapshot") else { return Snapshot() }
        return (try? JSONDecoder().decode(Snapshot.self, from: data)) ?? Snapshot()
    }

    func save() {
        Kota.defaults?.set(try? JSONEncoder().encode(self), forKey: "snapshot")
    }

    static let placeholder = Snapshot(providers: [
        ProviderUsage(name: "Claude", windows: [
            UsageWindow(title: "Session", usedPercent: 35, resetsAt: nil),
            UsageWindow(title: "Weekly", usedPercent: 60, resetsAt: nil),
        ]),
    ])
}

enum UsageFetcher {
    struct HTTPError: LocalizedError {
        let status: Int
        var errorDescription: String? {
            switch self.status {
            case 401, 403: "Rejected (HTTP \(self.status)). The sign-in may have expired; sign in again."
            default: "HTTP \(self.status)"
            }
        }
    }

    struct Failure: LocalizedError {
        var errorDescription: String?
        static let parse = Failure(errorDescription: "Unexpected response")
        static let signedOut = Failure(errorDescription: "Not signed in")
    }

    /// Fetches every account in parallel, keeping an account's last good bars when its fetch fails.
    static func fetchAll() async -> Snapshot {
        let previous = Snapshot.cached
        let accounts = Account.all
        let providers = await withTaskGroup(of: ProviderUsage.self) { group in
            for account in accounts {
                group.addTask {
                    do {
                        return try await ProviderUsage(id: account.id, name: account.name, windows: self.fetch(account))
                    } catch {
                        return ProviderUsage(
                            id: account.id,
                            name: account.name,
                            windows: previous.providers.first { $0.id == account.id }?.windows ?? [],
                            error: error.localizedDescription)
                    }
                }
            }
            var byID: [UUID: ProviderUsage] = [:]
            for await usage in group { byID[usage.id] = usage }
            return accounts.compactMap { byID[$0.id] }
        }
        let snapshot = Snapshot(providers: providers)
        snapshot.save()
        return snapshot
    }

    static func fetch(_ account: Account) async throws -> [UsageWindow] {
        guard let token = account.secret() else { throw Failure.signedOut }
        switch account.kind {
        case .claude: return try await self.claude(sessionKey: token)
        case .codex: return try await self.codex(account)
        case .opencodeGo:
            return try await self.parseOpenCodeGo(self.get(
                "https://opencode.ai/zen/go/v1/usage",
                headers: ["Authorization": "Bearer \(token)", "User-Agent": "CodexBar"]))
        }
    }

    // MARK: Claude (claude.ai web API, same endpoints as the Mac app's "Web API" source)

    // ponytail: no sessionKey rotation tracking (the Mac app follows Set-Cookie renewals); sign in again on expiry.
    static func claude(sessionKey: String) async throws -> [UsageWindow] {
        let headers = ["Cookie": "sessionKey=\(sessionKey)"]
        let orgs = try await self.get("https://claude.ai/api/organizations", headers: headers)
        let org = try self.parseClaudeOrganization(orgs)
        return try await self.parseClaude(self.get("https://claude.ai/api/organizations/\(org)/usage", headers: headers))
    }

    static func parseClaudeOrganization(_ data: Data) throws -> String {
        guard let orgs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw Failure.parse }
        let chat = orgs.first { ($0["capabilities"] as? [String])?.contains("chat") == true }
        guard let uuid = (chat ?? orgs.first)?["uuid"] as? String else { throw Failure.parse }
        return uuid
    }

    static func parseClaude(_ data: Data) throws -> [UsageWindow] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.parse }
        let keys = [
            ("Session", "five_hour"), ("Weekly", "seven_day"),
            ("Sonnet", "seven_day_sonnet"), ("Opus", "seven_day_opus"),
        ]
        return keys.compactMap { title, key in
            guard let window = json[key] as? [String: Any],
                  let used = (window["utilization"] as? NSNumber)?.doubleValue
            else { return nil }
            return UsageWindow(
                title: title,
                usedPercent: used,
                resetsAt: (window["resets_at"] as? String).flatMap(self.parseDate))
        }
    }

    // MARK: OpenCode Go (public usage API, API key auth)

    static func parseOpenCodeGo(_ data: Data, now: Date = Date()) throws -> [UsageWindow] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = json["usage"] as? [String: Any]
        else { throw Failure.parse }
        let windows: [UsageWindow] = [("5-hour", "rolling"), ("Weekly", "weekly"), ("Monthly", "monthly")]
            .compactMap { title, key in
                guard let window = usage[key] as? [String: Any],
                      // The API reports percentage units (1 == 1%).
                      let used = ["percent", "usagePercent", "usedPercent"].lazy
                      .compactMap({ (window[$0] as? NSNumber)?.doubleValue }).first
                else { return nil }
                let resetIn = ["resetInSec", "resetInSeconds", "resetsInSec"].lazy
                    .compactMap { (window[$0] as? NSNumber)?.doubleValue }.first
                let resetAt = ["resetAt", "resetsAt", "reset_at", "resets_at"].lazy
                    .compactMap { (window[$0] as? String).flatMap(self.parseDate) }.first
                return UsageWindow(
                    title: title,
                    usedPercent: used,
                    resetsAt: resetIn.map { now.addingTimeInterval($0) } ?? resetAt)
            }
        guard !windows.isEmpty else { throw Failure.parse }
        return windows
    }

    // MARK: Codex (ChatGPT backend, same endpoint as the Mac app's OAuth source)

    static func codex(_ account: Account) async throws -> [UsageWindow] {
        func usage() async throws -> [UsageWindow] {
            try await self.parseCodex(self.get(
                "https://chatgpt.com/backend-api/wham/usage",
                headers: ["Authorization": "Bearer \(account.secret() ?? "")", "User-Agent": "CodexBar"]))
        }
        do {
            return try await usage()
        } catch let error as HTTPError where error.status == 401 {
            // Only tokens from "Sign in with ChatGPT" can refresh; a pasted access token just expires.
            guard let refresh = account.secret(.refresh) else { throw error }
            // ponytail: app and widget can race to spend the single-use refresh token; the loser's refresh fails
            // and the retry below uses whatever the winner stored. Add a cross-process lock if this bites.
            try? await self.codexToken(
                ["grant_type": "refresh_token", "refresh_token": refresh, "scope": "openid profile email"],
                asJSON: true,
                for: account)
            return try await usage()
        }
    }

    static func parseCodex(_ data: Data) throws -> [UsageWindow] {
        struct Response: Decodable {
            struct Window: Decodable {
                let used_percent: Double
                let reset_at: Double?
            }

            struct RateLimit: Decodable {
                let primary_window: Window?
                let secondary_window: Window?
            }

            let rate_limit: RateLimit?
        }
        guard let limit = try? JSONDecoder().decode(Response.self, from: data).rate_limit else { throw Failure.parse }
        return [("Session", limit.primary_window), ("Weekly", limit.secondary_window)].compactMap { title, window in
            guard let window else { return nil }
            return UsageWindow(
                title: title,
                usedPercent: window.used_percent,
                resetsAt: window.reset_at.map { Date(timeIntervalSince1970: $0) })
        }
    }

    // MARK: Codex sign-in (the Codex CLI's OAuth client; request shapes mirror the CLI and the Mac app's refresher)

    static let codexClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let codexRedirectURI = "http://localhost:1455/auth/callback"

    static func codexAuthorizeURL(challenge: String, state: String) -> URL {
        URL(string: "https://auth.openai.com/oauth/authorize?" + self.formEncode([
            "response_type": "code",
            "client_id": self.codexClientID,
            "redirect_uri": self.codexRedirectURI,
            "scope": "openid profile email offline_access",
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "id_token_add_organizations": "true",
            "codex_cli_simplified_flow": "true",
            "state": state,
            "originator": "codex_cli_rs",
        ]))!
    }

    /// Extracts the authorization code from the raw HTTP request the browser sends to the localhost redirect.
    /// Returns nil for unrelated requests (favicon, preconnect); throws when the callback itself is bad.
    static func codexCallbackCode(request: String, state: String) throws -> String? {
        let parts = request.split(separator: "\r\n").first?.split(separator: " ") ?? []
        guard parts.count >= 2, let url = URLComponents(string: "http://localhost\(parts[1])"),
              url.path == "/auth/callback"
        else { return nil }
        let items = Dictionary((url.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { first, _ in first }
        // The state check stops another page from feeding us its own authorization code.
        guard items["state"] == state, let code = items["code"], !code.isEmpty else { throw Failure.parse }
        return code
    }

    /// Calls the OpenAI token endpoint (code exchange or refresh) and stores the returned tokens on the account.
    static func codexToken(_ params: [String: String], asJSON: Bool = false, for account: Account) async throws {
        let params = params.merging(["client_id": self.codexClientID]) { first, _ in first }
        var request = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue(
            asJSON ? "application/json" : "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type")
        request.httpBody = asJSON ? try JSONSerialization.data(withJSONObject: params) : Data(self.formEncode(params).utf8)
        let (data, response) = try await self.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw HTTPError(status: status) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String
        else { throw Failure.parse }
        guard account.setSecret(access) else { throw Failure(errorDescription: "Couldn't save to the Keychain") }
        if let refresh = json["refresh_token"] as? String { account.setSecret(refresh, .refresh) }
    }

    // MARK: Helpers

    static func formEncode(_ params: [String: String]) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return params.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
    }

    static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    /// Ephemeral + no cookie handling: the headers we set are the only credentials sent.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config)
    }()

    private static func get(_ url: String, headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let (data, response) = try await self.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw HTTPError(status: status) }
        return data
    }
}
