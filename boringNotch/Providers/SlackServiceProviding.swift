//
//  SlackServiceProviding.swift
//  boringNotch
//
//  Slack Web API client. Token is a user OAuth token (xoxp-…) from a
//  personal Slack app; see docs/slack/README.md for the app manifest.
//

import Foundation
import Security

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
        case .notAuthenticated: return "No Slack token configured"
        case .invalidToken: return "Slack rejected the token"
        case .rateLimited(let s): return "Rate limited by Slack (retry in \(Int(s))s)"
        case .httpError(let code): return "Slack HTTP error \(code)"
        case .apiError(let e): return "Slack API error: \(e)"
        case .invalidResponse: return "Unexpected response from Slack"
        }
    }
}

// MARK: - Protocol

protocol SlackServiceProviding: Sendable {
    func testAuth(token: String) async throws -> SlackIdentity
    func fetchDMSummaries(token: String) async throws -> [SlackDMSummary]
    func fetchMentions(token: String, userID: String, newerThan ts: String?) async throws -> [SlackMention]
    func setStatus(token: String, text: String, emoji: String, expiresAt: Date?) async throws
    func setSnooze(token: String, minutes: Int) async throws -> SlackDNDState
    func endSnooze(token: String) async throws -> SlackDNDState
    func fetchDND(token: String) async throws -> SlackDNDState
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
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: configuration)
    }

    // MARK: Endpoints

    func testAuth(token: String) async throws -> SlackIdentity {
        let response: AuthTestResponse = try await call("auth.test", token: token)
        return SlackIdentity(
            userID: response.user_id ?? "",
            userName: response.user ?? "",
            teamName: response.team ?? ""
        )
    }

    func fetchDMSummaries(token: String) async throws -> [SlackDMSummary] {
        let list: ConversationsListResponse = try await call(
            "conversations.list",
            query: ["types": "im,mpim", "exclude_archived": "true", "limit": "200"],
            token: token
        )
        let conversations = (list.channels ?? []).prefix(Self.maxTrackedDMs)

        var summaries: [SlackDMSummary] = []
        for conversation in conversations {
            let info: ConversationsInfoResponse = try await call(
                "conversations.info",
                query: ["channel": conversation.id],
                token: token
            )
            let unread = info.channel?.unread_count_display ?? 0
            guard unread > 0 else { continue }

            let name: String
            if conversation.is_mpim == true {
                name = conversation.name ?? "Group DM"
            } else if let counterpart = conversation.user {
                name = try await nameCache.displayName(for: counterpart) {
                    let userInfo: UsersInfoResponse = try await self.call(
                        "users.info", query: ["user": counterpart], token: token
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

    func fetchMentions(token: String, userID: String, newerThan ts: String?) async throws -> [SlackMention] {
        let response: SearchMessagesResponse = try await call(
            "search.messages",
            query: [
                "query": "<@\(userID)>",
                "count": "20",
                "sort": "timestamp",
                "sort_dir": "desc",
            ],
            token: token
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

    func setStatus(token: String, text: String, emoji: String, expiresAt: Date?) async throws {
        let expiration = expiresAt.map { Int($0.timeIntervalSince1970) } ?? 0
        let body: [String: Any] = [
            "profile": [
                "status_text": text,
                "status_emoji": emoji,
                "status_expiration": expiration,
            ]
        ]
        let _: BareOKResponse = try await call("users.profile.set", jsonBody: body, token: token)
    }

    func setSnooze(token: String, minutes: Int) async throws -> SlackDNDState {
        let response: DNDResponse = try await call(
            "dnd.setSnooze", query: ["num_minutes": String(minutes)], token: token
        )
        return response.dndState
    }

    func endSnooze(token: String) async throws -> SlackDNDState {
        // dnd.endSnooze errors with "snooze_not_active" if none is active; treat as success.
        do {
            let response: DNDResponse = try await call("dnd.endSnooze", method: "POST", token: token)
            return response.dndState
        } catch SlackServiceError.apiError(let message) where message == "snooze_not_active" {
            return SlackDNDState(snoozeEnabled: false, snoozeEndsAt: nil)
        }
    }

    func fetchDND(token: String) async throws -> SlackDNDState {
        let response: DNDResponse = try await call("dnd.info", token: token)
        return response.dndState
    }

    // MARK: Transport

    private func call<Response: SlackAPIResponse>(
        _ method: String,
        query: [String: String] = [:],
        jsonBody: [String: Any]? = nil,
        method httpMethod: String? = nil,
        token: String
    ) async throws -> Response {
        guard var components = URLComponents(string: Self.baseURL + method) else {
            throw SlackServiceError.invalidResponse
        }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw SlackServiceError.invalidResponse }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let jsonBody {
            request.httpMethod = "POST"
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        } else {
            request.httpMethod = httpMethod ?? "GET"
        }

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
            if error == "invalid_auth" || error == "token_revoked" || error == "account_inactive" {
                throw SlackServiceError.invalidToken
            }
            throw SlackServiceError.apiError(error)
        }
        return decoded
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

// MARK: - Keychain token storage

/// Stores the Slack user token as a generic password in the app's sandboxed keychain.
/// First Keychain use in this codebase — tokens must not live in Defaults/UserDefaults.
struct SlackKeychainTokenStore {
    private static let service = "theboringteam.boringnotch.slack"
    private static let account = "user-oauth-token"

    func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty
        else { return nil }
        return token
    }

    func save(_ token: String) {
        delete()
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecValueData as String: Data(token.utf8),
        ]
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
