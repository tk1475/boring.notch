//
//  SlackServiceProviding.swift
//  boringNotch
//
//  Slack Web API client. Supports two auth modes:
//   - .app     an OAuth user token (xoxp-…) from a personal Slack app
//   - .session a browser session token (xoxc-…) + `d` cookie (xoxd-…)
//  See docs/slack/README.md for how to obtain each.
//

import Foundation
import Defaults
import Security

// MARK: - Auth

enum SlackAuthMode: String, Defaults.Serializable {
    case app
    case session
}

enum SlackAuth: Sendable {
    case bearer(String)                       // xoxp / xoxb
    case session(token: String, cookie: String)  // xoxc + xoxd
}

// MARK: - Models

struct SlackIdentity: Sendable, Equatable {
    let userID: String
    let userName: String
    let teamName: String
}

struct SlackDMSummary: Identifiable, Sendable, Equatable {
    let id: String          // conversation ID
    let name: String        // counterpart display name or group name
    let unreadCount: Int
    let isGroup: Bool
}

struct SlackMention: Identifiable, Sendable, Equatable {
    let id: String          // channelID + ts
    let channelName: String
    let userName: String
    let text: String
    let timestamp: String   // Slack ts, e.g. "1726650000.000100" (sortable)
    let permalink: URL?
}

struct SlackDNDState: Sendable, Equatable {
    var snoozeEnabled: Bool
    var snoozeEndsAt: Date?
}

enum SlackServiceError: LocalizedError {
    case notAuthenticated
    case invalidToken
    case rateLimited(retryAfter: TimeInterval)
    case httpError(Int)
    case apiError(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "No Slack credentials configured"
        case .invalidToken: return "Slack rejected the credentials"
        case .rateLimited(let s): return "Rate limited by Slack (retry in \(Int(s))s)"
        case .httpError(let code): return "Slack HTTP error \(code)"
        case .apiError(let e): return "Slack API error: \(e)"
        case .invalidResponse: return "Unexpected response from Slack"
        }
    }
}

// MARK: - Protocol

protocol SlackServiceProviding: Sendable {
    func testAuth(auth: SlackAuth) async throws -> SlackIdentity
    func fetchDMSummaries(auth: SlackAuth) async throws -> [SlackDMSummary]
    func fetchMentions(auth: SlackAuth, userID: String, newerThan ts: String?) async throws -> [SlackMention]
    func setStatus(auth: SlackAuth, text: String, emoji: String, expiresAt: Date?) async throws
    func setSnooze(auth: SlackAuth, minutes: Int) async throws -> SlackDNDState
    func endSnooze(auth: SlackAuth) async throws -> SlackDNDState
    func fetchDND(auth: SlackAuth) async throws -> SlackDNDState
}

// MARK: - Service

final class SlackService: SlackServiceProviding {
    private static let baseURL = "https://slack.com/api/"
    private static let maxTrackedDMs = 25

    private let session: URLSession
    private static let decoder = JSONDecoder()

    // Cache of userID -> display name to avoid repeated users.info calls.
    private let nameCache = SlackNameCache()

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil   // we set the `d` cookie manually
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: configuration)
    }

    // MARK: Endpoints

    func testAuth(auth: SlackAuth) async throws -> SlackIdentity {
        let response: AuthTestResponse = try await call("auth.test", auth: auth)
        return SlackIdentity(
            userID: response.user_id ?? "",
            userName: response.user ?? "",
            teamName: response.team ?? ""
        )
    }

    func fetchDMSummaries(auth: SlackAuth) async throws -> [SlackDMSummary] {
        let list: ConversationsListResponse = try await call(
            "conversations.list",
            params: ["types": "im,mpim", "exclude_archived": "true", "limit": "200"],
            auth: auth
        )
        let conversations = (list.channels ?? []).prefix(Self.maxTrackedDMs)

        var summaries: [SlackDMSummary] = []
        for conversation in conversations {
            let info: ConversationsInfoResponse = try await call(
                "conversations.info",
                params: ["channel": conversation.id],
                auth: auth
            )
            let unread = info.channel?.unread_count_display ?? 0
            guard unread > 0 else { continue }

            let name: String
            if conversation.is_mpim == true {
                name = conversation.name ?? "Group DM"
            } else if let counterpart = conversation.user {
                name = try await nameCache.displayName(for: counterpart) {
                    let userInfo: UsersInfoResponse = try await self.call(
                        "users.info", params: ["user": counterpart], auth: auth
                    )
                    return userInfo.user?.profile?.display_name.flatMap { $0.isEmpty ? nil : $0 }
                        ?? userInfo.user?.real_name
                        ?? userInfo.user?.name
                        ?? counterpart
                }
            } else {
                name = "DM"
            }
            summaries.append(SlackDMSummary(
                id: conversation.id,
                name: name,
                unreadCount: unread,
                isGroup: conversation.is_mpim == true
            ))
        }
        return summaries.sorted { $0.unreadCount > $1.unreadCount }
    }

    func fetchMentions(auth: SlackAuth, userID: String, newerThan ts: String?) async throws -> [SlackMention] {
        let response: SearchMessagesResponse = try await call(
            "search.messages",
            params: [
                "query": "<@\(userID)>",
                "count": "20",
                "sort": "timestamp",
                "sort_dir": "desc",
            ],
            auth: auth
        )
        let matches = response.messages?.matches ?? []
        return matches.compactMap { match -> SlackMention? in
            guard let messageTs = match.ts else { return nil }
            if let newerThan = ts, messageTs <= newerThan { return nil }
            return SlackMention(
                id: "\(match.channel?.id ?? "")-\(messageTs)",
                channelName: match.channel?.name ?? "unknown",
                userName: match.username ?? "someone",
                text: match.text ?? "",
                timestamp: messageTs,
                permalink: match.permalink.flatMap(URL.init(string:))
            )
        }
    }

    func setStatus(auth: SlackAuth, text: String, emoji: String, expiresAt: Date?) async throws {
        let expiration = expiresAt.map { Int($0.timeIntervalSince1970) } ?? 0
        let profile: [String: Any] = [
            "status_text": text,
            "status_emoji": emoji,
            "status_expiration": expiration,
        ]
        let profileJSON = String(
            data: try JSONSerialization.data(withJSONObject: profile), encoding: .utf8
        ) ?? "{}"
        let _: BareOKResponse = try await call(
            "users.profile.set", params: ["profile": profileJSON], auth: auth
        )
    }

    func setSnooze(auth: SlackAuth, minutes: Int) async throws -> SlackDNDState {
        let response: DNDResponse = try await call(
            "dnd.setSnooze", params: ["num_minutes": String(minutes)], auth: auth
        )
        return response.dndState
    }

    func endSnooze(auth: SlackAuth) async throws -> SlackDNDState {
        // dnd.endSnooze errors with "snooze_not_active" if none is active; treat as success.
        do {
            let response: DNDResponse = try await call("dnd.endSnooze", auth: auth)
            return response.dndState
        } catch SlackServiceError.apiError(let message) where message == "snooze_not_active" {
            return SlackDNDState(snoozeEnabled: false, snoozeEndsAt: nil)
        }
    }

    func fetchDND(auth: SlackAuth) async throws -> SlackDNDState {
        let response: DNDResponse = try await call("dnd.info", auth: auth)
        return response.dndState
    }

    // MARK: Transport

    /// All calls are POST application/x-www-form-urlencoded, which every Slack
    /// Web API method accepts and which session (xoxc) tokens require.
    private func call<Response: SlackAPIResponse>(
        _ method: String,
        params: [String: String] = [:],
        auth: SlackAuth
    ) async throws -> Response {
        guard let url = URL(string: Self.baseURL + method) else {
            throw SlackServiceError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )

        var body = params
        switch auth {
        case .bearer(let token):
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .session(let token, let cookie):
            body["token"] = token
            request.setValue("d=\(cookie)", forHTTPHeaderField: "Cookie")
        }
        request.httpBody = Self.formEncode(body)

        let (data, urlResponse) = try await session.data(for: request)
        guard let http = urlResponse as? HTTPURLResponse else {
            throw SlackServiceError.invalidResponse
        }
        switch http.statusCode {
        case 200...299:
            break
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 30
            throw SlackServiceError.rateLimited(retryAfter: retryAfter)
        case 401, 403:
            throw SlackServiceError.invalidToken
        default:
            throw SlackServiceError.httpError(http.statusCode)
        }

        let decoded = try Self.decoder.decode(Response.self, from: data)
        if decoded.ok != true {
            let error = decoded.error ?? "unknown_error"
            if error == "invalid_auth" || error == "token_revoked"
                || error == "account_inactive" || error == "not_authed" {
                throw SlackServiceError.invalidToken
            }
            throw SlackServiceError.apiError(error)
        }
        return decoded
    }

    private static func formEncode(_ params: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let pairs = params.map { key, value -> String in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }
}

// MARK: - Name cache

private actor SlackNameCache {
    private var names: [String: String] = [:]

    func displayName(for userID: String, resolve: () async throws -> String) async rethrows -> String {
        if let cached = names[userID] { return cached }
        let resolved = try await resolve()
        names[userID] = resolved
        return resolved
    }
}

// MARK: - Wire types

private protocol SlackAPIResponse: Decodable {
    var ok: Bool? { get }
    var error: String? { get }
}

private struct BareOKResponse: SlackAPIResponse {
    let ok: Bool?
    let error: String?
}

private struct AuthTestResponse: SlackAPIResponse {
    let ok: Bool?
    let error: String?
    let user_id: String?
    let user: String?
    let team: String?
}

private struct ConversationsListResponse: SlackAPIResponse {
    struct Conversation: Decodable {
        let id: String
        let name: String?
        let is_im: Bool?
        let is_mpim: Bool?
        let user: String?
    }
    let ok: Bool?
    let error: String?
    let channels: [Conversation]?
}

private struct ConversationsInfoResponse: SlackAPIResponse {
    struct Channel: Decodable {
        let id: String
        let unread_count_display: Int?
    }
    let ok: Bool?
    let error: String?
    let channel: Channel?
}

private struct UsersInfoResponse: SlackAPIResponse {
    struct Profile: Decodable {
        let display_name: String?
    }
    struct User: Decodable {
        let name: String?
        let real_name: String?
        let profile: Profile?
    }
    let ok: Bool?
    let error: String?
    let user: User?
}

private struct SearchMessagesResponse: SlackAPIResponse {
    struct ChannelRef: Decodable {
        let id: String?
        let name: String?
    }
    struct Match: Decodable {
        let ts: String?
        let text: String?
        let username: String?
        let permalink: String?
        let channel: ChannelRef?
    }
    struct Messages: Decodable {
        let matches: [Match]?
    }
    let ok: Bool?
    let error: String?
    let messages: Messages?
}

private struct DNDResponse: SlackAPIResponse {
    let ok: Bool?
    let error: String?
    let snooze_enabled: Bool?
    let snooze_endtime: TimeInterval?

    var dndState: SlackDNDState {
        SlackDNDState(
            snoozeEnabled: snooze_enabled ?? false,
            snoozeEndsAt: snooze_endtime.map { Date(timeIntervalSince1970: $0) }
        )
    }
}

// MARK: - Keychain credential storage

/// Stores Slack secrets as generic passwords in the app's sandboxed keychain.
/// Secrets must not live in Defaults/UserDefaults; only the non-secret
/// `slackAuthMode` selector does.
struct SlackKeychainTokenStore {
    private static let service = "theboringteam.boringnotch.slack"

    enum Item: String {
        case appToken = "user-oauth-token"    // xoxp
        case sessionToken = "session-token"   // xoxc
        case sessionCookie = "session-cookie" // xoxd (the `d` cookie value)
    }

    func read(_ item: Item) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: item.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    func save(_ value: String, for item: Item) {
        delete(item)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: item.rawValue,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func delete(_ item: Item) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: item.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
    }

    func deleteAll() {
        delete(.appToken)
        delete(.sessionToken)
        delete(.sessionCookie)
    }
}
