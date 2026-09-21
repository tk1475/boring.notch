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
    @Published var isInHuddle: Bool = false
    /// Text shown in the closed-notch banner when a new mention arrives.
    @Published var bannerText: String = ""

    var totalUnreadDMs: Int { dmSummaries.reduce(0) { $0 + $1.unreadCount } }
    var hasCredentials: Bool { currentAuth() != nil }

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
        let interval = max(15, Defaults[.slackPollIntervalSeconds])
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

            // Detect DMs whose unread count grew since the last poll, so we can
            // name the sender rather than just show a total.
            let newDMs = dms.filter { $0.unreadCount > (previousDMUnread[$0.id] ?? 0) }
            previousDMUnread = Dictionary(uniqueKeysWithValues: dms.map { ($0.id, $0.unreadCount) })

            dmSummaries = dms
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
            bannerText = "@\(latest.userName) in #\(latest.channelName)"
        } else {
            bannerText = "\(newMentions.count) new mentions"
        }
        BoringViewCoordinator.shared.toggleExpandingView(status: true, type: .slack)
    }

    private func announceDMs(_ newDMs: [SlackDMSummary]) {
        if newDMs.count == 1, let dm = newDMs.first {
            bannerText = dm.isGroup ? "\(dm.name) (group)" : "DM from \(dm.name)"
        } else {
            bannerText = "\(newDMs.count) new DMs"
        }
        BoringViewCoordinator.shared.toggleExpandingView(status: true, type: .slack)
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
