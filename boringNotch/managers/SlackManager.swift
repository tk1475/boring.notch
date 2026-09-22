//
//  SlackManager.swift
//  boringNotch
//
//  Polls the Slack Web API for unread DMs, mentions, and DND state, and
//  detects huddles locally via CoreAudio (Slack has no public huddle API).
//

import AppKit
import Combine
import CoreAudio
import Defaults
import SwiftUI

enum SlackConnectionState: Equatable {
    case disconnected
    case connecting
    case connected(SlackIdentity)
    case failed(String)
}

@MainActor
class SlackManager: ObservableObject {
    static let shared = SlackManager()

    @Published var connectionState: SlackConnectionState = .disconnected
    @Published var dmSummaries: [SlackDMSummary] = []
    @Published var mentions: [SlackMention] = []
    @Published var dndState = SlackDNDState(snoozeEnabled: false, snoozeEndsAt: nil)
    @Published var status = SlackStatus(text: "", emoji: "", expiresAt: nil)
    @Published var isInHuddle: Bool = false
    /// Text shown in the closed-notch banner when a new mention/DM arrives.
    @Published var bannerText: String = ""
    /// Sender identity for the banner avatar (falls back to the Slack mark).
    @Published var bannerAvatarURL: URL?
    @Published var bannerAvatarName: String = ""
    @Published var bannerIsGroup: Bool = false

    var totalUnreadDMs: Int { dmSummaries.reduce(0) { $0 + $1.unreadCount } }
    var hasCredentials: Bool { currentAuth() != nil }

    /// The status emoji rendered as a unicode glyph, when known.
    var statusGlyph: String? { SlackMessageFormatter.emojiGlyph(for: status.emoji) }

    /// Whether there's any Slack presence worth showing persistently on the notch.
    var hasSlackPresence: Bool {
        status.isSet || dndState.snoozeEnabled || isInHuddle
    }

    /// Short label for the persistent notch presence indicator.
    var notchPresenceText: String {
        if status.isSet { return status.text.isEmpty ? "Status set" : status.text }
        if isInHuddle { return "In a huddle" }
        if dndState.snoozeEnabled { return "Do not disturb" }
        return ""
    }

    private let service: SlackServiceProviding = SlackService()
    private let tokenStore = SlackKeychainTokenStore()
    private let huddleDetector = SlackHuddleDetector()
    private var pollTask: Task<Void, Never>?
    private var identity: SlackIdentity?
    /// Set true after the first successful poll; gates banners so pre-existing
    /// unreads at launch don't all fire notifications.
    private var establishedBaseline = false
    /// Last seen unread count per DM conversation, to detect newly arrived DMs.
    private var previousDMUnread: [String: Int] = [:]
    /// DMs the user has opened from the panel; hidden until the server marks
    /// them read (they drop off) or a new message arrives (they return).
    private var dismissedDMs: Set<String> = []

    private init() {
        if Defaults[.enableSlackIntegration], hasCredentials {
            start()
        }
    }

    // MARK: Credentials

    /// Builds the auth for the currently selected mode, or nil if the required
    /// secrets for that mode are missing.
    private func currentAuth() -> SlackAuth? {
        switch Defaults[.slackAuthMode] {
        case .app:
            guard let token = tokenStore.read(.appToken) else { return nil }
            return .bearer(token)
        case .session:
            guard let token = tokenStore.read(.sessionToken),
                  let cookie = tokenStore.read(.sessionCookie) else { return nil }
            return .session(token: token, cookie: cookie)
        }
    }

    func setAppToken(_ token: String) {
        tokenStore.save(token.trimmingCharacters(in: .whitespacesAndNewlines), for: .appToken)
        Defaults[.slackAuthMode] = .app
        restartWithFreshIdentity()
    }

    func setSessionCredentials(token: String, cookie: String) {
        tokenStore.save(token.trimmingCharacters(in: .whitespacesAndNewlines), for: .sessionToken)
        tokenStore.save(cookie.trimmingCharacters(in: .whitespacesAndNewlines), for: .sessionCookie)
        Defaults[.slackAuthMode] = .session
        restartWithFreshIdentity()
    }

    func clearCredentials() {
        tokenStore.deleteAll()
        identity = nil
        stop()
        dmSummaries = []
        mentions = []
        dismissedDMs = []
    }

    private func restartWithFreshIdentity() {
        identity = nil
        stop()
        if Defaults[.enableSlackIntegration] {
            start()
        }
    }

    // MARK: Lifecycle

    func start() {
        guard pollTask == nil else { return }
        guard hasCredentials else {
            connectionState = .disconnected
            return
        }
        connectionState = .connecting
        establishedBaseline = false
        previousDMUnread = [:]
        dismissedDMs = []
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                let delay = await self.pollOnce()
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        connectionState = .disconnected
    }

    /// Called from AppDelegate.applicationWillTerminate.
    func destroy() {
        stop()
    }

    // MARK: Opening in Slack

    /// Opens a DM in Slack and removes it from the panel right away. The next
    /// poll keeps it hidden until Slack marks it read (then it's forgotten) or a
    /// new message arrives (then it returns).
    func openDM(_ dm: SlackDMSummary) {
        openConversation(id: dm.id)
        dismissedDMs.insert(dm.id)
        dmSummaries.removeAll { $0.id == dm.id }
    }

    /// Opens a mention in Slack and removes it from the panel.
    func openMention(_ mention: SlackMention) {
        if !mention.channelID.isEmpty {
            openConversation(id: mention.channelID, messageTs: mention.timestamp)
        } else if let permalink = mention.permalink {
            NSWorkspace.shared.open(permalink)
        }
        mentions.removeAll { $0.id == mention.id }
    }

    /// Opens a conversation in the Slack desktop app via a `slack://` deep link,
    /// falling back to the web client when the app isn't installed. `messageTs`
    /// deep-links to a specific message (used for mentions).
    func openConversation(id: String, messageTs: String? = nil) {
        let teamID = identity?.teamID ?? ""
        var deepLinkString = "slack://channel?team=\(teamID)&id=\(id)"
        if let messageTs { deepLinkString += "&message=\(messageTs)" }

        let deepLink = URL(string: deepLinkString)
        let webURL = URL(string: "https://app.slack.com/client/\(teamID)/\(id)")

        if !teamID.isEmpty, let deepLink,
           NSWorkspace.shared.urlForApplication(toOpen: deepLink) != nil {
            NSWorkspace.shared.open(deepLink)
        } else if !teamID.isEmpty, let webURL {
            NSWorkspace.shared.open(webURL)
        }
    }

    // MARK: Quick actions

    func setStatus(text: String, emoji: String, expiresIn minutes: Int?) async {
        guard let auth = currentAuth() else { return }
        let expiry = minutes.map { Date().addingTimeInterval(TimeInterval($0 * 60)) }
        do {
            try await service.setStatus(auth: auth, text: text, emoji: emoji, expiresAt: expiry)
        } catch {
            NSLog("SlackManager: setStatus failed: \(error.localizedDescription)")
        }
    }

    func clearStatus() async {
        await setStatus(text: "", emoji: "", expiresIn: nil)
    }

    func snooze(minutes: Int) async {
        guard let auth = currentAuth() else { return }
        do {
            dndState = try await service.setSnooze(auth: auth, minutes: minutes)
        } catch {
            NSLog("SlackManager: snooze failed: \(error.localizedDescription)")
        }
    }

    func endSnooze() async {
        guard let auth = currentAuth() else { return }
        do {
            dndState = try await service.endSnooze(auth: auth)
        } catch {
            NSLog("SlackManager: endSnooze failed: \(error.localizedDescription)")
        }
    }

    // MARK: Polling

    /// Runs one poll cycle; returns the delay in seconds before the next one.
    private func pollOnce() async -> TimeInterval {
        let interval = max(5, Defaults[.slackPollIntervalSeconds])
        guard let auth = currentAuth() else {
            connectionState = .disconnected
            return interval
        }

        do {
            if identity == nil {
                identity = try await service.testAuth(auth: auth)
            }
            guard let identity else { return interval }
            connectionState = .connected(identity)

            // First poll after launch/auth establishes a baseline: populate the
            // panel but don't fire banners for pre-existing mentions/DMs.
            let isBaselinePoll = !establishedBaseline
            let dms = try await service.fetchDMSummaries(auth: auth)
            let newMentions = try await service.fetchMentions(
                auth: auth,
                userID: identity.userID,
                newerThan: Defaults[.slackLastSeenMentionTs].isEmpty ? nil : Defaults[.slackLastSeenMentionTs]
            )
            let dnd = try await service.fetchDND(auth: auth)
            // Status is non-critical; a failure here shouldn't break the poll.
            if let fetchedStatus = try? await service.fetchStatus(auth: auth) {
                status = fetchedStatus
            }

            // Detect DMs whose unread count grew since the last poll, so we can
            // name the sender rather than just show a total.
            let newDMs = dms.filter { $0.unreadCount > (previousDMUnread[$0.id] ?? 0) }
            previousDMUnread = Dictionary(uniqueKeysWithValues: dms.map { ($0.id, $0.unreadCount) })

            // A new message in a dismissed DM brings it back; once the server no
            // longer reports a DM unread, stop tracking its dismissal.
            for dm in newDMs { dismissedDMs.remove(dm.id) }
            dismissedDMs.formIntersection(Set(dms.map(\.id)))

            dmSummaries = dms.filter { !dismissedDMs.contains($0.id) }
            dndState = dnd

            if !newMentions.isEmpty {
                mentions = Array((newMentions + mentions).prefix(20))
                if let newest = newMentions.map(\.timestamp).max() {
                    Defaults[.slackLastSeenMentionTs] = newest
                }
                if !isBaselinePoll { announceMentions(newMentions) }
            } else if !isBaselinePoll, Defaults[.slackShowBanners], Defaults[.slackNotifyDMs], !newDMs.isEmpty {
                announceDMs(newDMs)
            }
            establishedBaseline = true
        } catch SlackServiceError.rateLimited(let retryAfter) {
            return max(retryAfter, interval)
        } catch SlackServiceError.invalidToken {
            connectionState = .failed("Slack rejected the token — re-authenticate in Settings")
            stop()
            return interval
        } catch {
            connectionState = .failed(error.localizedDescription)
        }

        if Defaults[.slackHuddleDetection] {
            isInHuddle = huddleDetector.slackIsUsingMicrophone()
        }
        return interval
    }

    private func announceMentions(_ newMentions: [SlackMention]) {
        guard Defaults[.slackShowBanners] else { return }
        if let latest = newMentions.first {
            bannerText = "\(latest.userName) in #\(latest.channelName)"
            setBannerSender(name: latest.userName, avatarURL: latest.avatarURL, isGroup: false)
        } else {
            bannerText = "\(newMentions.count) new mentions"
            setBannerSender(name: "Slack", avatarURL: nil, isGroup: false)
        }
        BoringViewCoordinator.shared.toggleExpandingView(status: true, type: .slack)
    }

    private func announceDMs(_ newDMs: [SlackDMSummary]) {
        if newDMs.count == 1, let dm = newDMs.first {
            bannerText = dm.name
            setBannerSender(name: dm.name, avatarURL: dm.avatarURL, isGroup: dm.isGroup)
        } else {
            bannerText = "\(newDMs.count) new direct messages"
            setBannerSender(name: "Slack", avatarURL: nil, isGroup: newDMs.count > 1)
        }
        BoringViewCoordinator.shared.toggleExpandingView(status: true, type: .slack)
    }

    private func setBannerSender(name: String, avatarURL: URL?, isGroup: Bool) {
        bannerAvatarName = name
        bannerAvatarURL = avatarURL
        bannerIsGroup = isGroup
    }
}

// MARK: - Huddle detection

/// Best-effort "am I in a huddle" signal: checks whether the Slack app is
/// actively capturing audio input, via the CoreAudio process-object API
/// (macOS 14.4+). Slack exposes no public huddle API.
final class SlackHuddleDetector {
    private static let slackBundleID = "com.tinyspeck.slackmacgap"

    func slackIsUsingMicrophone() -> Bool {
        guard #available(macOS 14.4, *) else { return false }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr, dataSize > 0 else { return false }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var processObjects = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &processObjects
        ) == noErr else { return false }

        for processObject in processObjects {
            guard bundleID(of: processObject) == Self.slackBundleID else { continue }
            if isRunningInput(processObject) { return true }
        }
        return false
    }

    @available(macOS 14.4, *)
    private func bundleID(of processObject: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(processObject, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return nil }
        var value: CFString = "" as CFString
        guard AudioObjectGetPropertyData(processObject, &address, 0, nil, &dataSize, &value) == noErr
        else { return nil }
        return value as String
    }

    @available(macOS 14.4, *)
    private func isRunningInput(_ processObject: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(processObject, &address, 0, nil, &dataSize, &value) == noErr
        else { return false }
        return value != 0
    }
}
